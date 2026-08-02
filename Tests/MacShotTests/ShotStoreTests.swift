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

    // MARK: - 缩略图重画

    /// 追加修订之后缩略图**必须**被重画。
    ///
    /// 缩略图是 `save()` 时按原图生成、以 sha256 命名的，而 sha 只认原图字节 ——
    /// 加多少标注它都不变。少了这一步，图库网格会一直显示没有标注的那一版
    /// （用户报的「编辑完返回图库图片没更新」）。
    ///
    /// 重画是**异步**的（整段渲染 + 编码 + 写盘挂在后台，主线程只回来作废缓存 ——
    /// 同步跑会在编辑时每隔一秒多堵一次主线程），所以这里要等它完成。
    func testAppendRevisionRefreshesThumbnail() async throws {
        let (store, _) = try makeStore()
        let shot = try store.save(image: makeImage(gray: 0.1), metadata: CaptureMetadata())

        let thumbURL = store.thumbnailURL(for: shot)
        let before = try Data(contentsOf: thumbURL)

        // 渲染器由 App 层注入；这里给一个「把整张涂成另一个灰度」的假实现，
        // 只要产物与原图不同就能验证「确实重画过」。
        store.revisionThumbnailRenderer = { [self] _, _ in
            (try? makeImage(gray: 0.9)) ?? (try! makeImage(gray: 0.9))
        }

        var invalidated: [String] = []
        store.thumbnailInvalidator = { invalidated.append($0.sha256) }

        _ = store.appendRevision(shot: shot, layers: Layers(), note: "测试")

        // 轮询等它落地，而不是睡一个固定时长 —— 固定 sleep 在慢机器上会假失败，
        // 在快机器上白等。上限 2 秒，超时即判定「根本没重画」。
        let deadline = Date().addingTimeInterval(2)
        while invalidated.isEmpty, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }

        let after = try Data(contentsOf: thumbURL)
        XCTAssertNotEqual(before, after, "追加修订后缩略图文件没有被重画")
        XCTAssertEqual(invalidated, [shot.sha256], "重画之后必须作废内存缓存里那份旧的")
    }

    /// 没注入渲染器时（测试、命令行）不重画也不崩 —— 缩略图是派生数据，
    /// 画不出来最多显示旧的一版，不该让修订保存失败。
    func testAppendRevisionWithoutRendererIsSafe() throws {
        let (store, _) = try makeStore()
        let shot = try store.save(image: makeImage(gray: 0.2), metadata: CaptureMetadata())

        let revision = store.appendRevision(shot: shot, layers: Layers(), note: "测试")
        XCTAssertNotNil(revision, "没有渲染器不该影响修订本身落库")
    }

    // MARK: - 导入本地图片

    /// 导入**不重新编码**：磁盘上落的必须是原始字节。
    ///
    /// 这是导入路径与截图路径最根本的差别。若一律转 PNG，
    /// 一张 JPEG 会膨胀好几倍、动图 GIF 会丢掉动画。
    func testImportPreservesOriginalBytes() throws {
        let (store, _) = try makeStore()

        // 用 JPEG 作被导入文件：它转成 PNG 一定会变大且字节不同，
        // 「原样保存」与「重新编码」因此可区分。
        let image = try makeImage(gray: 0.42)
        let jpeg = try XCTUnwrap(ImageCodec.jpegData(from: image))
        let source = tempRoot.appendingPathComponent("photo.jpg")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        try jpeg.write(to: source)

        let shot = try XCTUnwrap(store.importImage(at: source), "导入应当成功")

        XCTAssertEqual(shot.fileExtension, "jpg", "扩展名要记住原格式")
        XCTAssertTrue(shot.originalFileName.hasSuffix(".jpg"))
        XCTAssertTrue(shot.isImported, "没有来源 App 即为导入")

        let stored = try Data(contentsOf: store.originalURL(for: shot))
        XCTAssertEqual(stored, jpeg, "落盘的必须是原始字节，一个都不能变")

        // 缩略图仍是我们自己生成的 JPEG（派生数据，格式由我们说了算）。
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.thumbnailURL(for: shot).path))
    }

    /// 原文件名要能搜到 —— 导入之后按原名找得回来是这条路径的基本要求。
    func testImportRecordsSearchableFileName() throws {
        let (store, _) = try makeStore()

        let image = try makeImage(gray: 0.3)
        let png = try XCTUnwrap(ImageCodec.pngData(from: image))
        let source = tempRoot.appendingPathComponent("季度报表截图.png")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        try png.write(to: source)

        let shot = try XCTUnwrap(store.importImage(at: source))
        let id = try XCTUnwrap(shot.id)
        XCTAssertEqual(store.attributeText(shotID: id, key: AttributeKey.importName), "季度报表截图.png")

        store.searchText = "季度报表"
        store.reload()
        XCTAssertEqual(store.shots.first?.id, id, "按原文件名应当搜得到")
    }

    /// 非图片文件不进库。
    func testImportRejectsNonImage() throws {
        let (store, _) = try makeStore()
        let source = tempRoot.appendingPathComponent("note.txt")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: source)

        XCTAssertNil(store.importImage(at: source), "解不出图像的文件不该入库")
    }

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

    // 这里曾经有三条测试盯着 `.today` / `.thisWeek` 的时间边界（今天 00:00 的
    // 前后一秒、周起始跟随地区设置、时间筛选与搜索叠加）。那两个筛选在
    // 「简化侧边栏」时连同 UI 一起删掉了 —— 网格本来就按日期分组、最新在最上，
    // 「今天」等于滚到顶。测试随被测能力一起移除，而不是留着测不存在的东西。

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

    // MARK: - 搜索

    /// **两字词必须能搜到。** FTS5 的 trigram 分词器索引的是三字符片段，
    /// 少于 3 个字符的 MATCH 永远返回空 —— 而中文里两字词是绝对主力
    /// （文档、报告、终端、代码…）。短查询要绕开 FTS 走 LIKE 兜底。
    func testShortQueryFallsBackToLikeSearch() throws {
        let (store, _) = try makeStore()

        var doc = CaptureMetadata()
        doc.appName = "预览"
        doc.windowTitle = "季度文档汇总"
        _ = try store.save(image: makeImage(gray: 0.1), metadata: doc)

        var other = CaptureMetadata()
        other.appName = "Xcode"
        other.windowTitle = "ContentView.swift"
        _ = try store.save(image: makeImage(gray: 0.2), metadata: other)

        // 两个汉字：走 LIKE。
        store.searchText = "文档"
        store.reload()
        XCTAssertEqual(store.shots.count, 1, "两字词搜不到 —— trigram 的 3 字符下限没兜住")
        XCTAssertEqual(store.shots.first?.windowTitle, "季度文档汇总")

        // 两个 ASCII 字符同理。
        store.searchText = "预览"
        store.reload()
        XCTAssertEqual(store.shots.count, 1)

        // 三个字符以上继续走 FTS，行为不变。
        store.searchText = "ContentView"
        store.reload()
        XCTAssertEqual(store.shots.count, 1)
        XCTAssertEqual(store.shots.first?.appName, "Xcode")
    }

    /// 短查询里的 `%` `_` 是 LIKE 的通配符，必须转义 ——
    /// 否则搜「%」会把整个库都匹配出来。
    func testShortQueryEscapesLikeWildcards() throws {
        let (store, _) = try makeStore()

        var withPercent = CaptureMetadata()
        withPercent.windowTitle = "CPU 90% 占用"
        _ = try store.save(image: makeImage(gray: 0.1), metadata: withPercent)

        var plain = CaptureMetadata()
        plain.windowTitle = "普通标题"
        _ = try store.save(image: makeImage(gray: 0.2), metadata: plain)

        store.searchText = "0%"
        store.reload()
        XCTAssertEqual(store.shots.count, 1, "通配符没转义，把不含 % 的也匹配了")
        XCTAssertEqual(store.shots.first?.windowTitle, "CPU 90% 占用")
    }

    /// 短查询也要受侧边栏筛选收窄，不能绕开筛选条件。
    func testShortQueryStillHonorsFilter() throws {
        let (store, _) = try makeStore()

        var a = CaptureMetadata()
        a.appName = "预览"
        let shotA = try store.save(image: makeImage(gray: 0.1), metadata: a)

        var b = CaptureMetadata()
        b.appName = "预览"
        _ = try store.save(image: makeImage(gray: 0.2), metadata: b)

        store.toggleFavorite(shotA)

        store.searchText = "预览"
        store.filter = .favorites
        store.reload()
        XCTAssertEqual(store.shots.count, 1, "短查询绕开了收藏筛选")
        XCTAssertEqual(store.shots.first?.id, shotA.id)
    }
}
