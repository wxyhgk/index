import XCTest
import CoreGraphics
import GRDB
@testable import MacShot

/// ShotStore 的行为安全网：清理候选的豁免规则、批量删除的引用计数、
/// 侧边栏四个智能筛选（今天 / 本周 / 未整理 / 已标注）的边界与计数。
/// 全部用内存库 + 临时目录，不碰真实的 Application Support。
@MainActor
final class ShotStoreTests: XCTestCase {

    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacShotTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
    }

    /// 内存库 + 临时根目录的 ShotStore。返回 dbQueue 供测试直接改库（比如回填拍摄时间）。
    private func makeStore() throws -> (store: ShotStore, dbQueue: DatabaseQueue) {
        let dbQueue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(dbQueue)
        return (ShotStore(rootDirectory: tempRoot, database: dbQueue), dbQueue)
    }

    /// 纯色小图。gray 不同 → 像素不同 → sha256 不同。
    private func makeImage(gray: CGFloat) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: gray, green: gray, blue: gray, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        return try XCTUnwrap(context.makeImage())
    }

    /// 把一批截图的拍摄时间改到过去 —— save() 固定写当前时间，测试需要老图。
    private func backdate(_ ids: [Int64], to date: Date, in dbQueue: DatabaseQueue) throws {
        try dbQueue.write { db in
            for id in ids {
                try db.execute(
                    sql: "UPDATE shot SET capturedAt = ? WHERE id = ?",
                    arguments: [date, id]
                )
            }
        }
    }

    // MARK: - 清理候选

    /// 有标签 / 收藏 / 修订（标注过）的截图不进清理候选；过期且无保护的进。
    func testCleanupCandidatesExemptProtectedShots() throws {
        let (store, dbQueue) = try makeStore()

        let plain = try store.save(image: makeImage(gray: 0.1), metadata: CaptureMetadata())
        let tagged = try store.save(image: makeImage(gray: 0.2), metadata: CaptureMetadata())
        let favorited = try store.save(image: makeImage(gray: 0.3), metadata: CaptureMetadata())
        let annotated = try store.save(image: makeImage(gray: 0.4), metadata: CaptureMetadata())
        let recent = try store.save(image: makeImage(gray: 0.5), metadata: CaptureMetadata())

        // 前四张回填成 10 天前的老图；recent 保持当前时间。
        let oldDate = Date().addingTimeInterval(-10 * 86_400)
        try backdate(
            [plain.id!, tagged.id!, favorited.id!, annotated.id!],
            to: oldDate, in: dbQueue
        )

        store.addTag(shotID: tagged.id!, "工作")
        store.toggleFavorite(favorited)
        let layer = Layer(kind: .rect, rect: LRect(x: 0, y: 0, w: 4, h: 4))
        XCTAssertNotNil(store.appendRevision(
            shot: annotated, layers: Layers<ImageSpace>([layer]), note: nil
        ))

        let cutoff = Date().addingTimeInterval(-86_400)
        let candidates = store.cleanupCandidates(olderThan: cutoff, limit: 10)

        XCTAssertEqual(candidates.map(\.id), [plain.id], "只有过期且无任何保护的截图进候选")
        _ = recent // recent 未过期，不应出现 —— 上面的相等断言已覆盖。
    }

    // MARK: - 批量删除的引用计数

    /// 同 sha 两张截图：删一张文件保留，删第二张文件消失。
    func testBatchDeleteKeepsSharedOriginalUntilLastReference() throws {
        let (store, _) = try makeStore()
        let image = try makeImage(gray: 0.6)

        let first = try store.save(image: image, metadata: CaptureMetadata())
        let second = try store.save(image: image, metadata: CaptureMetadata())
        XCTAssertEqual(first.sha256, second.sha256, "同内容必须内容寻址去重")
        XCTAssertNotEqual(first.id, second.id)

        let originalPath = store.originalURL(for: first).path
        let thumbnailPath = store.thumbnailURL(for: first).path
        XCTAssertTrue(FileManager.default.fileExists(atPath: originalPath))

        store.delete([first])
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: originalPath),
            "sha 仍被另一条记录引用，原图必须保留"
        )
        XCTAssertEqual(store.totalCount, 1)

        store.delete([second])
        XCTAssertFalse(FileManager.default.fileExists(atPath: originalPath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: thumbnailPath))
        XCTAssertEqual(store.totalCount, 0)
    }

    /// 同一批里同时删掉同 sha 的所有记录：同一事务里算引用计数，文件删干净。
    func testBatchDeleteRemovesFileWhenAllReferencesGoInOneBatch() throws {
        let (store, _) = try makeStore()
        let shared = try makeImage(gray: 0.7)

        let first = try store.save(image: shared, metadata: CaptureMetadata())
        let second = try store.save(image: shared, metadata: CaptureMetadata())
        let survivor = try store.save(image: makeImage(gray: 0.8), metadata: CaptureMetadata())

        let sharedPath = store.originalURL(for: first).path
        let survivorPath = store.originalURL(for: survivor).path

        store.delete([first, second])

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: sharedPath),
            "全部引用在同一批里删光，文件必须消失"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: survivorPath), "无关截图不受影响")
        XCTAssertEqual(store.totalCount, 1)
    }

    // MARK: - 智能筛选

    /// 按筛选跑一次 reload，返回网格里实际会显示的 ID（时间倒序）。
    private func filteredIDs(_ store: ShotStore, _ filter: ShotStore.GalleryFilter) -> [Int64] {
        store.filter = filter
        store.reload()
        return store.shots.compactMap(\.id)
    }

    /// `.today`：边界是「今天 00:00」，昨天 23:59 不算今天。
    /// 边界由 `Calendar.dateInterval(of: .day)` 给出，不是「现在减 86400」。
    func testTodayFilterExcludesYesterdayJustBeforeMidnight() throws {
        let (store, dbQueue) = try makeStore()
        let today = ShotStore.dayInterval()

        let justAfterMidnight = try store.save(image: makeImage(gray: 0.1),
                                               metadata: CaptureMetadata())
        let justBeforeMidnight = try store.save(image: makeImage(gray: 0.2),
                                                metadata: CaptureMetadata())
        let lastWeek = try store.save(image: makeImage(gray: 0.3), metadata: CaptureMetadata())

        try backdate([justAfterMidnight.id!],
                     to: today.start.addingTimeInterval(1), in: dbQueue)
        // 昨天 23:59:59 —— 与今天起点只差一秒，是最容易写错的那个边界。
        try backdate([justBeforeMidnight.id!],
                     to: today.start.addingTimeInterval(-1), in: dbQueue)
        try backdate([lastWeek.id!],
                     to: today.start.addingTimeInterval(-7 * 86_400), in: dbQueue)

        XCTAssertEqual(filteredIDs(store, .today), [justAfterMidnight.id],
                       "只有今天 00:00 之后拍的进「今天」")
        XCTAssertEqual(store.todayCount(), 1)
    }

    /// `.thisWeek`：周起始跟随 `Calendar.firstWeekday`（地区设置），不硬编码周一或周日；
    /// 上一周的最后一秒不算本周。
    func testThisWeekFilterUsesLocaleWeekStart() throws {
        let (store, dbQueue) = try makeStore()
        let week = ShotStore.weekInterval()
        let calendar = Calendar.current

        XCTAssertEqual(
            calendar.component(.weekday, from: week.start), calendar.firstWeekday,
            "周起始日必须来自地区设置，不能硬编码"
        )

        let atWeekStart = try store.save(image: makeImage(gray: 0.1), metadata: CaptureMetadata())
        let beforeWeekStart = try store.save(image: makeImage(gray: 0.2),
                                             metadata: CaptureMetadata())
        let midWeek = try store.save(image: makeImage(gray: 0.3), metadata: CaptureMetadata())

        try backdate([atWeekStart.id!], to: week.start, in: dbQueue)
        try backdate([beforeWeekStart.id!],
                     to: week.start.addingTimeInterval(-1), in: dbQueue)
        // 本周内、今天之前的某一刻（就算今天正好是周起始日也仍落在区间里）。
        try backdate([midWeek.id!], to: week.start.addingTimeInterval(60), in: dbQueue)

        XCTAssertEqual(Set(filteredIDs(store, .thisWeek)), [atWeekStart.id!, midWeek.id!],
                       "上一周最后一秒不算本周；周起点当刻算本周")
        XCTAssertEqual(store.thisWeekCount(), 2)
        XCTAssertEqual(filteredIDs(store, .today).count, store.todayCount(),
                       "同一份数据下筛选结果数与徽章计数必须一致")
    }

    /// 时间筛选和搜索词是叠加的：搜索决定候选集，筛选再收窄一次。
    func testTodayFilterCombinesWithSearchText() throws {
        let (store, dbQueue) = try makeStore()
        let today = ShotStore.dayInterval()

        var safari = CaptureMetadata()
        safari.appName = "Safari"
        var xcode = CaptureMetadata()
        xcode.appName = "Xcode"

        let todaySafari = try store.save(image: makeImage(gray: 0.1), metadata: safari)
        let todayXcode = try store.save(image: makeImage(gray: 0.2), metadata: xcode)
        let oldSafari = try store.save(image: makeImage(gray: 0.3), metadata: safari)

        try backdate([todaySafari.id!, todayXcode.id!],
                     to: today.start.addingTimeInterval(1), in: dbQueue)
        try backdate([oldSafari.id!],
                     to: today.start.addingTimeInterval(-86_400), in: dbQueue)

        store.searchText = "Safari"
        defer { store.searchText = "" }

        // 只搜索：两张 Safari 都在，时间倒序（今天那张在前）。
        XCTAssertEqual(filteredIDs(store, .all), [todaySafari.id!, oldSafari.id!])
        XCTAssertEqual(filteredIDs(store, .today), [todaySafari.id],
                       "搜索 + 今天：两个条件同时生效")
    }

    /// `.untagged`：打了标签就离开「未整理」，标签删掉之后要重新算作未整理。
    func testUntaggedFilterRecountsAfterTagRemoval() throws {
        let (store, _) = try makeStore()

        let plain = try store.save(image: makeImage(gray: 0.1), metadata: CaptureMetadata())
        let tagged = try store.save(image: makeImage(gray: 0.2), metadata: CaptureMetadata())

        XCTAssertEqual(Set(filteredIDs(store, .untagged)), [plain.id!, tagged.id!])
        XCTAssertEqual(store.untaggedCount(), 2)

        store.addTag(shotID: tagged.id!, "工作")
        store.addTag(shotID: tagged.id!, "报销")
        XCTAssertEqual(filteredIDs(store, .untagged), [plain.id])
        XCTAssertEqual(store.untaggedCount(), 1, "多值 tag 不能把同一张图重复计数")

        store.removeTag(shotID: tagged.id!, "工作")
        XCTAssertEqual(filteredIDs(store, .untagged), [plain.id], "还剩一个标签，仍算整理过")
        XCTAssertEqual(store.untaggedCount(), 1)

        store.removeTag(shotID: tagged.id!, "报销")
        XCTAssertEqual(Set(filteredIDs(store, .untagged)), [plain.id!, tagged.id!],
                       "标签全删光后必须重新回到未整理")
        XCTAssertEqual(store.untaggedCount(), 2)

        // 收藏之类的其它属性不是标签，不影响「未整理」判定。
        store.toggleFavorite(plain)
        XCTAssertEqual(store.untaggedCount(), 2)
    }

    /// `.annotated` 的口径必须与卡片右下角铅笔角标（`annotatedShotIDs`）完全一致：
    /// 修订数 > 1。入库自动建的那条「原始」空修订不算标注。
    func testAnnotatedFilterMatchesCardBadge() throws {
        let (store, _) = try makeStore()

        let plain = try store.save(image: makeImage(gray: 0.1), metadata: CaptureMetadata())
        let annotated = try store.save(image: makeImage(gray: 0.2), metadata: CaptureMetadata())
        let twiceEdited = try store.save(image: makeImage(gray: 0.3), metadata: CaptureMetadata())

        let layer = Layer(kind: .rect, rect: LRect(x: 0, y: 0, w: 4, h: 4))
        XCTAssertNotNil(store.appendRevision(
            shot: annotated, layers: Layers<ImageSpace>([layer]), note: nil
        ))
        XCTAssertNotNil(store.appendRevision(
            shot: twiceEdited, layers: Layers<ImageSpace>([layer]), note: nil
        ))
        XCTAssertNotNil(store.appendRevision(
            shot: twiceEdited, layers: Layers<ImageSpace>([layer, layer]), note: nil
        ))

        let filtered = Set(filteredIDs(store, .annotated))
        XCTAssertEqual(filtered, [annotated.id!, twiceEdited.id!])
        XCTAssertEqual(store.annotatedCount(), 2, "改两次仍然只算一张图")

        let allIDs = [plain.id!, annotated.id!, twiceEdited.id!]
        XCTAssertEqual(filtered, store.annotatedShotIDs(among: allIDs),
                       "筛选口径与卡片铅笔角标必须逐张对齐")
    }

    /// 未整理筛选靠 v4 建的 (shotID, key) 复合索引，不能退化成全表扫描 ——
    /// 这四个查询跟着侧边栏每轮刷新跑。
    func testUntaggedQueryUsesCompositeIndex() throws {
        let (_, dbQueue) = try makeStore()

        let plan = try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                EXPLAIN QUERY PLAN
                SELECT COUNT(*) FROM shot
                WHERE NOT EXISTS (
                    SELECT 1 FROM shotAttribute
                    WHERE shotAttribute.shotID = shot.id AND shotAttribute.key = ?
                )
                """, arguments: [AttributeKey.tag])
                .map { $0["detail"] as String }
                .joined(separator: " | ")
        }
        XCTAssertTrue(
            plan.contains("index_shotAttribute_on_shotID_key"),
            "查询计划应命中复合索引，实际为：\(plan)"
        )
    }
}
