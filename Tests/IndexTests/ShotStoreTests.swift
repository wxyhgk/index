import XCTest
import CoreGraphics
import GRDB
@testable import IndexApp

/// ShotStore 的行为安全网：清理候选的豁免规则、批量删除的引用计数、
/// 侧边栏四个智能筛选（今天 / 本周 / 未整理 / 已标注）的边界与计数。
/// 全部用内存库 + 临时目录，不碰真实的 Application Support。
@MainActor
final class ShotStoreTests: XCTestCase {

    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("IndexTests-\(UUID().uuidString)", isDirectory: true)
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

    func testMoleculeSourceAttachmentPersistsAsTypedAsset() throws {
        let (store, dbQueue) = try makeStore()
        let shot = try store.save(image: makeImage(gray: 0.15), metadata: CaptureMetadata())
        let source = MoleculeSourceAttachment(
            canonicalXYZ: "2\nH2\nH 0 0 0\nH 0 0 0.74\n",
            atomCount: 2,
            createdAt: Date(timeIntervalSince1970: 456)
        )

        try store.attachMoleculeSource(source, to: shot)

        XCTAssertEqual(store.moleculeSource(for: shot), source)
        try dbQueue.read { db in
            let asset = try XCTUnwrap(ShotAsset.fetchOne(db))
            XCTAssertEqual(asset.kind, ShotAssetKind.moleculeXYZ)
            XCTAssertEqual(asset.schemaVersion, MoleculeSourceAttachment.currentSchemaVersion)
            XCTAssertEqual(try ShotAttribute.fetchCount(db), 0)
        }
    }

    func testCustomTitleIsSearchableAndNeverRenamesOriginalFile() throws {
        let (store, _) = try makeStore()
        var metadata = CaptureMetadata()
        metadata.appName = "Microsoft Edge"
        metadata.windowTitle = "论文截图"
        let shot = try store.save(image: makeImage(gray: 0.18), metadata: metadata)
        let originalURL = store.originalURL(for: shot)

        store.setCustomTitle("  MR-TADF molecule  ", for: shot)
        store.reload(query: "molecule", filter: .all)

        XCTAssertEqual(store.shots.map(\.id), [shot.id])
        XCTAssertEqual(store.shots.first?.primaryDisplayName, "MR-TADF molecule")
        XCTAssertEqual(store.originalURL(for: try XCTUnwrap(store.shots.first)), originalURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: originalURL.path))

        store.setCustomTitle(" \n ", for: shot)
        store.reload(query: "", filter: .all)

        XCTAssertNil(store.shots.first?.customTitle)
        XCTAssertEqual(store.shots.first?.primaryDisplayName, "论文截图")
        XCTAssertEqual(store.originalURL(for: try XCTUnwrap(store.shots.first)), originalURL)
    }

    // MARK: - 清理候选

    /// 有标签 / 收藏 / 专题归类 / 修订（标注过）的截图不进清理候选；过期且无保护的进。
    func testCleanupCandidatesExemptProtectedShots() throws {
        let (store, dbQueue) = try makeStore()

        let plain = try store.save(image: makeImage(gray: 0.1), metadata: CaptureMetadata())
        let tagged = try store.save(image: makeImage(gray: 0.2), metadata: CaptureMetadata())
        let favorited = try store.save(image: makeImage(gray: 0.3), metadata: CaptureMetadata())
        let annotated = try store.save(image: makeImage(gray: 0.4), metadata: CaptureMetadata())
        let organized = try store.save(image: makeImage(gray: 0.5), metadata: CaptureMetadata())
        let recent = try store.save(image: makeImage(gray: 0.6), metadata: CaptureMetadata())
        let recording = try store.save(image: makeImage(gray: 0.7), metadata: CaptureMetadata())

        // 前五张回填成 10 天前的老图；recent 保持当前时间。
        let oldDate = Date().addingTimeInterval(-10 * 86_400)
        try backdate(
            [plain.id!, tagged.id!, favorited.id!, annotated.id!, organized.id!, recording.id!],
            to: oldDate, in: dbQueue
        )

        store.addTag(shotID: tagged.id!, "工作")
        store.toggleFavorite(favorited)
        let layer = Layer(kind: .rect, rect: LRect(x: 0, y: 0, w: 4, h: 4))
        XCTAssertNotNil(store.appendRevision(
            shot: annotated, layers: Layers<ImageSpace>([layer]), note: nil
        ))
        let collection = try store.createCollection(name: "MR-TADF 分子")
        try store.addToCollection(
            shotIDs: [try XCTUnwrap(organized.id)],
            collectionID: try XCTUnwrap(collection.id)
        )
        try store.attachRecording(at: URL(fileURLWithPath: "/tmp/protected-recording.mp4"), to: recording)

        let cutoff = Date().addingTimeInterval(-86_400)
        let candidates = store.cleanupCandidates(olderThan: cutoff, limit: 10)

        XCTAssertEqual(candidates.map(\.id), [plain.id], "只有过期且无任何保护的截图进候选")
        _ = recent // recent 未过期，不应出现 —— 上面的相等断言已覆盖。
    }

    // MARK: - 专题收藏集

    func testCollectionsAreManyToManyAndMembershipIsIdempotent() throws {
        let (store, _) = try makeStore()
        let first = try store.save(image: makeImage(gray: 0.12), metadata: CaptureMetadata())
        let second = try store.save(image: makeImage(gray: 0.34), metadata: CaptureMetadata())
        let firstID = try XCTUnwrap(first.id)
        let secondID = try XCTUnwrap(second.id)

        let molecules = try store.createCollection(name: "MR-TADF 分子")
        let papers = try store.createCollection(name: "论文配图")
        let moleculeID = try XCTUnwrap(molecules.id)
        let papersID = try XCTUnwrap(papers.id)

        try store.addToCollection(shotIDs: [firstID, secondID, firstID], collectionID: moleculeID)
        try store.addToCollection(shotIDs: [firstID], collectionID: papersID)

        let summaries = Dictionary(uniqueKeysWithValues: store.collectionSummaries().map { ($0.id, $0) })
        XCTAssertEqual(summaries[moleculeID]?.itemCount, 2, "重复加入必须幂等")
        XCTAssertEqual(summaries[papersID]?.itemCount, 1)
        XCTAssertEqual(Set(summaries[moleculeID]?.previews.compactMap(\.id) ?? []), [firstID, secondID])

        let memberships = store.collectionMemberships(shotIDs: [firstID, secondID])
        XCTAssertEqual(memberships[firstID], [moleculeID, papersID], "同一张图可以属于多个专题集")
        XCTAssertEqual(memberships[secondID], [moleculeID])

        XCTAssertEqual(Set(filteredIDs(store, .collection(moleculeID))), [firstID, secondID])
        XCTAssertEqual(Set(filteredIDs(store, .collection(papersID))), [firstID])
    }

    func testDeletingCollectionKeepsShotsAndDeletingShotCleansMembership() throws {
        let (store, _) = try makeStore()
        let first = try store.save(image: makeImage(gray: 0.21), metadata: CaptureMetadata())
        let second = try store.save(image: makeImage(gray: 0.43), metadata: CaptureMetadata())
        let firstID = try XCTUnwrap(first.id)
        let secondID = try XCTUnwrap(second.id)
        let collection = try store.createCollection(name: "计算化学")
        let collectionID = try XCTUnwrap(collection.id)
        try store.addToCollection(shotIDs: [firstID, secondID], collectionID: collectionID)

        store.delete([first])
        XCTAssertEqual(store.totalCount, 1)
        XCTAssertEqual(store.collectionSummaries().first?.itemCount, 1, "删图应级联清理成员关系")

        store.deleteCollection(id: collectionID)
        store.reload()
        XCTAssertEqual(store.collectionCount(), 0)
        XCTAssertEqual(store.totalCount, 1, "删除专题集绝不能删除原截图")
        XCTAssertEqual(store.shots.first?.id, second.id)
    }

    func testCollectionNamesTrimRejectDuplicatesAndCanRename() throws {
        let (store, _) = try makeStore()
        let collection = try store.createCollection(name: "  MR-TADF 分子  ")
        XCTAssertEqual(collection.name, "MR-TADF 分子")

        XCTAssertThrowsError(try store.createCollection(name: "mr-tadf 分子")) { error in
            XCTAssertEqual(error as? ShotCollectionError, .duplicateName)
        }
        XCTAssertThrowsError(try store.createCollection(name: "   ")) { error in
            XCTAssertEqual(error as? ShotCollectionError, .emptyName)
        }

        let id = try XCTUnwrap(collection.id)
        try store.renameCollection(id: id, to: "发光分子")
        XCTAssertEqual(store.collectionSummaries().first?.name, "发光分子")
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
    private func filteredIDs(_ store: ShotStore, _ filter: ShotFilter) -> [Int64] {
        store.reload(query: "", filter: filter)
        return store.shots.compactMap(\.id)
    }

    func testRecordingFilterAndBatchPathsExposeVideoAssets() async throws {
        let (store, _) = try makeStore()
        let recording = try store.save(
            image: makeImage(gray: 0.1),
            metadata: CaptureMetadata()
        )
        let screenshot = try store.save(
            image: makeImage(gray: 0.2),
            metadata: CaptureMetadata()
        )
        let path = "/tmp/example-recording.mp4"
        try store.attachRecording(at: URL(fileURLWithPath: path), to: recording)

        XCTAssertEqual(store.recordingPath(for: recording), path)

        XCTAssertEqual(filteredIDs(store, .recordings), [recording.id])
        XCTAssertFalse(filteredIDs(store, .recordings).contains(try XCTUnwrap(screenshot.id)))
        XCTAssertEqual(store.recordingCount(), 1)
        XCTAssertEqual(
            store.recordingPaths(
                for: [try XCTUnwrap(recording.id), try XCTUnwrap(screenshot.id)]
            )[try XCTUnwrap(recording.id)],
            path
        )
        XCTAssertEqual(store.recordingCount(), 1)
        let semanticCandidateIDs = await store.matchingShotIDsInBackground(filter: .recordings)
        XCTAssertEqual(semanticCandidateIDs, [try XCTUnwrap(recording.id)])
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

    /// 未整理筛选靠复合索引，不能退化成 shotAttribute 全表扫描 ——
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
            plan.contains("index_shotAttribute_on_key_shotID"),
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
        store.reload(query: "文档", filter: .all)
        XCTAssertEqual(store.shots.count, 1, "两字词搜不到 —— trigram 的 3 字符下限没兜住")
        XCTAssertEqual(store.shots.first?.windowTitle, "季度文档汇总")

        // 两个 ASCII 字符同理。
        store.reload(query: "预览", filter: .all)
        XCTAssertEqual(store.shots.count, 1)

        // 三个字符以上继续走 FTS，行为不变。
        store.reload(query: "ContentView", filter: .all)
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

        store.reload(query: "0%", filter: .all)
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

        store.reload(query: "预览", filter: .favorites)
        XCTAssertEqual(store.shots.count, 1, "短查询绕开了收藏筛选")
        XCTAssertEqual(store.shots.first?.id, shotA.id)
    }

    // MARK: - 同源时间线

    /// 网址匹配改成「SQL 前缀缩候选 + Swift 精确判定」之后，结果必须与从前一致。
    ///
    /// 此前是把全库带网址的行整个取回来再在 Swift 里筛，而它挂在详情栏上、
    /// 每选一张卡片就跑一次。前缀能成立是因为归一化只**截短**（去掉 #锚点、
    /// 去掉末尾斜杠），所以归一化结果必然是原串的前缀；但前缀会**多**命中
    /// （target 是 …/a 时 …/abc 也满足），所以精确过滤不能省 —— 这条正是盯它。
    func testRelatedShotsPrefixDoesNotOverMatch() throws {
        let (store, _) = try makeStore()

        func save(_ url: String, gray: CGFloat) throws -> Shot {
            var meta = CaptureMetadata()
            meta.sourceURL = url
            return try store.save(image: makeImage(gray: gray), metadata: meta)
        }

        let target = try save("https://example.com/a", gray: 0.1)
        // 同一页面的不同形态：带锚点、带末尾斜杠 —— 归一化后与 target 相同。
        let withHash = try save("https://example.com/a#section", gray: 0.2)
        let withSlash = try save("https://example.com/a/", gray: 0.3)
        // 前缀会命中但归一化后**不**相同 —— 精确过滤必须把它挡掉。
        _ = try save("https://example.com/abc", gray: 0.4)
        // 完全无关。
        _ = try save("https://other.com/x", gray: 0.5)

        let related = store.relatedShots(to: target)
        XCTAssertEqual(
            Set(related.compactMap(\.id)),
            Set([target.id, withHash.id, withSlash.id].compactMap { $0 }),
            "前缀多命中的 /abc 必须被精确过滤挡掉，同页面的三张都要在"
        )
    }

    // MARK: - 数据库观察与显式刷新

    /// 写路径不再自己安排 0.5 秒后的 reload；数据库提交应直接驱动当前列表快照。
    func testDatabaseObservationRefreshesInventoryWithoutExplicitReload() async throws {
        let (store, _) = try makeStore()
        let changed = expectation(description: "ValueObservation 发布新库存")
        let token = store.libraryDidChange.sink { changed.fulfill() }
        defer { token.cancel() }

        let shot = try store.save(image: makeImage(gray: 0.42), metadata: CaptureMetadata())

        await fulfillment(of: [changed], timeout: 1)
        XCTAssertEqual(store.shots.compactMap(\.id), [shot.id].compactMap { $0 })
    }

    /// 收藏集名称不改变 Shot 行，但应用/收藏入口仍要收到库存聚合失效信号。
    func testDatabaseObservationIncludesCollectionMutations() async throws {
        let (store, _) = try makeStore()
        let changed = expectation(description: "收藏集提交触发库存聚合刷新")
        let token = store.libraryDidChange.sink { changed.fulfill() }
        defer { token.cancel() }

        _ = try store.createCollection(name: "MR-TADF")

        await fulfillment(of: [changed], timeout: 1)
        XCTAssertTrue(store.shots.isEmpty)
        XCTAssertEqual(store.collectionCount(), 1)
    }

    /// 普通图库不应因编辑器自动保存修订而反复刷新胶片条与侧边栏聚合。
    func testDatabaseObservationExcludesRevisionsFromOrdinaryInventory() async throws {
        let (store, _) = try makeStore()
        let shot = try store.save(image: makeImage(gray: 0.31), metadata: CaptureMetadata())
        store.reload(query: "", filter: .all)

        let changed = expectation(description: "普通库存不观察修订")
        changed.isInverted = true
        let token = store.libraryDidChange.sink { changed.fulfill() }
        defer { token.cancel() }

        XCTAssertNotNil(store.appendRevision(shot: shot, layers: Layers(), note: "标注"))
        await fulfillment(of: [changed], timeout: 0.1)
    }

    /// “已标注”筛选的成员资格正由修订决定，因此该查询必须观察 revision 表。
    func testAnnotatedObservationIncludesRevisionMutations() async throws {
        let (store, _) = try makeStore()
        let shot = try store.save(image: makeImage(gray: 0.73), metadata: CaptureMetadata())
        store.reload(query: "", filter: .annotated)
        XCTAssertTrue(store.shots.isEmpty)

        let changed = expectation(description: "已标注筛选观察修订")
        let token = store.libraryDidChange.sink { changed.fulfill() }
        defer { token.cancel() }

        XCTAssertNotNil(store.appendRevision(shot: shot, layers: Layers(), note: "标注"))
        await fulfillment(of: [changed], timeout: 1)
        XCTAssertEqual(store.shots.compactMap(\.id), [shot.id].compactMap { $0 })
    }

    /// 同步 `reload()` 与后台 `reloadInBackground()` 必须给出**同样的结果**。
    ///
    /// 它们共用 `ShotQueryRepository.fetchRows` 那一份 SQL，正是为了防止两条路慢慢长歪 ——
    /// 这条测试就是那份共用的守卫：将来谁只改了其中一条，这里会红。
    func testBackgroundReloadMatchesSyncReload() async throws {
        let (store, _) = try makeStore()

        var safari = CaptureMetadata()
        safari.appName = "Safari"
        _ = try store.save(image: makeImage(gray: 0.1), metadata: safari)
        _ = try store.save(image: makeImage(gray: 0.2), metadata: safari)

        var xcode = CaptureMetadata()
        xcode.appName = "Xcode"
        _ = try store.save(image: makeImage(gray: 0.3), metadata: xcode)

        // 无筛选无搜索
        store.reload()
        let syncAll = store.shots.map(\.id)
        await store.reloadInBackground()
        XCTAssertEqual(store.shots.map(\.id), syncAll, "无条件时两条路径结果应一致")

        // 叠加筛选 + 搜索：分支最多的那条路
        let appFilter = ShotFilter.app(CapturedAppIdentity(name: "Safari", bundleID: nil))
        store.reload(query: "Safari", filter: appFilter)
        let syncFiltered = store.shots.map(\.id)
        XCTAssertEqual(syncFiltered.count, 2)

        await store.reloadInBackground(query: "Safari", filter: appFilter)
        XCTAssertEqual(store.shots.map(\.id), syncFiltered, "筛选 + 搜索下两条路径结果应一致")
    }

    /// 后台刷新同样要发「库存变了」的信号 —— 胶片条只订这个，
    /// 漏发就等于它再也不更新（那条信号正是为了让它别被修订保存惊动）。
    func testBackgroundReloadEmitsLibraryDidChange() async throws {
        let (store, _) = try makeStore()

        var received = 0
        let token = store.libraryDidChange.sink { received += 1 }
        defer { token.cancel() }

        await store.reloadInBackground()
        XCTAssertEqual(received, 1)
    }

    // MARK: - 应用首页聚合

    func testCapturedAppsUseStableIdentityAndLatestThreePreviews() throws {
        let (store, dbQueue) = try makeStore()
        let base = Date(timeIntervalSince1970: 10_000)

        func saveApp(
            _ name: String,
            bundleID: String?,
            gray: CGFloat,
            offset: TimeInterval
        ) throws -> Shot {
            var metadata = CaptureMetadata()
            metadata.appName = name
            metadata.appBundleID = bundleID
            let shot = try store.save(image: makeImage(gray: gray), metadata: metadata)
            try backdate([try XCTUnwrap(shot.id)], to: base.addingTimeInterval(offset), in: dbQueue)
            return shot
        }

        let first = try saveApp("Edge 旧名称", bundleID: "com.microsoft.edgemac", gray: 0.1, offset: 1)
        let second = try saveApp("Microsoft Edge", bundleID: "com.microsoft.edgemac", gray: 0.2, offset: 2)
        let third = try saveApp("Microsoft Edge", bundleID: "com.microsoft.edgemac", gray: 0.3, offset: 3)
        let fourth = try saveApp("Microsoft Edge", bundleID: "com.microsoft.edgemac", gray: 0.4, offset: 4)
        _ = first

        _ = try saveApp("Microsoft Edge", bundleID: "com.example.other-edge", gray: 0.5, offset: 5)
        _ = try saveApp("Microsoft Edge", bundleID: nil, gray: 0.6, offset: 6)

        let apps = store.capturedApps()
        XCTAssertEqual(apps.count, 3, "同 bundleID 要合并；同名但不同 bundleID 或无 bundleID 必须分开")

        let edge = try XCTUnwrap(apps.first { $0.bundleID == "com.microsoft.edgemac" })
        XCTAssertEqual(edge.name, "Microsoft Edge", "显示名取这个身份最近一张截图的名称")
        XCTAssertEqual(edge.captureCount, 4)
        XCTAssertEqual(edge.previews.compactMap(\.id), [fourth.id, third.id, second.id])
        XCTAssertEqual(edge.lastCapturedAt, base.addingTimeInterval(4))
    }

    func testAppFilterUsesBundleIDBeforeDisplayName() throws {
        let (store, _) = try makeStore()

        func saveApp(bundleID: String?, gray: CGFloat) throws -> Shot {
            var metadata = CaptureMetadata()
            metadata.appName = "同名应用"
            metadata.appBundleID = bundleID
            return try store.save(image: makeImage(gray: gray), metadata: metadata)
        }

        let target = try saveApp(bundleID: "com.example.target", gray: 0.11)
        _ = try saveApp(bundleID: "com.example.other", gray: 0.22)
        let fallback = try saveApp(bundleID: nil, gray: 0.33)

        store.reload(
            query: "",
            filter: .app(CapturedAppIdentity(name: "同名应用", bundleID: "com.example.target"))
        )
        XCTAssertEqual(store.shots.compactMap(\.id), [target.id])

        store.reload(
            query: "",
            filter: .app(CapturedAppIdentity(name: "同名应用", bundleID: nil))
        )
        XCTAssertEqual(store.shots.compactMap(\.id), [fallback.id])
    }

    // MARK: - 分页

    /// 翻页要**不重不漏**，且顺序与不分页时完全一致。
    func testPaginationCoversEveryRowExactlyOnce() async throws {
        let (store, dbQueue) = try makeStore()

        // 造 3 页多一点，其中一批**拍摄时间完全相同** —— 并列是游标分页最容易
        // 翻车的地方：排序不唯一时，游标定位会漏掉或重复并列的那一段。
        let total = ShotStore.pageSize * 2 + 7
        var ids: [Int64] = []
        for i in 0..<total {
            let shot = try store.save(
                image: makeImage(gray: Double(i) / Double(total)),
                metadata: CaptureMetadata()
            )
            ids.append(try XCTUnwrap(shot.id))
        }
        // 前 10 张压成同一时刻，制造并列。
        try backdate(Array(ids.prefix(10)), to: Date(timeIntervalSince1970: 1_000_000), in: dbQueue)

        store.reload()
        XCTAssertEqual(store.shots.count, ShotStore.pageSize, "第一页只取一页的量")
        XCTAssertTrue(store.hasMorePages)

        while store.hasMorePages {
            let before = store.shots.count
            await store.loadNextPage()
            XCTAssertGreaterThan(store.shots.count, before, "每次翻页都要有进展，否则会死循环")
        }

        let loaded = store.shots.compactMap(\.id)
        XCTAssertEqual(loaded.count, total, "翻完之后总数要对得上")
        XCTAssertEqual(Set(loaded).count, total, "不能有重复")
        XCTAssertEqual(loaded, loaded.sorted { a, b in
            let sa = store.shots.first { $0.id == a }!
            let sb = store.shots.first { $0.id == b }!
            return (sa.capturedAt, a) > (sb.capturedAt, b)
        }, "顺序必须是 (拍摄时间, id) 降序")
    }

    /// 库存提交会刷新第一页并重置游标；随后继续翻页仍必须不重不漏。
    func testPaginationRestartsCleanlyWhenRowsAreInsertedMidway() async throws {
        let (store, _) = try makeStore()

        let total = ShotStore.pageSize + 20
        for i in 0..<total {
            _ = try store.save(
                image: makeImage(gray: Double(i) / Double(total)),
                metadata: CaptureMetadata()
            )
        }

        store.reload()
        let firstPage = store.shots.compactMap(\.id)

        // 在翻下一页之前插入新截图（它们的时间最新，会排在最前）。持续观察应把
        // 第一页更新到新快照，而不是继续展示节流窗口里的陈旧页。
        var insertedIDs: [Int64] = []
        for i in 0..<5 {
            let shot = try store.save(
                image: makeImage(gray: 0.9 - Double(i) / 100),
                metadata: CaptureMetadata()
            )
            insertedIDs.append(try XCTUnwrap(shot.id))
        }
        await store.reloadInBackground()

        XCTAssertNotEqual(store.shots.compactMap(\.id), firstPage)
        XCTAssertEqual(
            Array(store.shots.compactMap(\.id).prefix(insertedIDs.count)),
            Array(insertedIDs.reversed())
        )

        await store.loadNextPage()
        let all = store.shots.compactMap(\.id)

        XCTAssertEqual(Set(all).count, all.count, "OFFSET 分页会在这里产生重复；游标不会")
        XCTAssertEqual(all.count, total + insertedIDs.count, "重置后的新游标必须覆盖完整库存")
    }

    /// 全选取的是「符合当前条件的全部」，不是「已经加载的那些」。
    func testSelectAllIDsIgnorePagination() async throws {
        let (store, database) = try makeStore()

        let total = ShotStore.pageSize + 50
        for i in 0..<total {
            _ = try store.save(
                image: makeImage(gray: Double(i) / Double(total)),
                metadata: CaptureMetadata()
            )
        }

        store.reload()
        XCTAssertEqual(store.shots.count, ShotStore.pageSize, "只加载了第一页")

        let ids = await store.allMatchingIDs(query: "", filter: .all)
        XCTAssertEqual(ids.count, total, "全选必须覆盖全部，而不是已加载的一页")

        let requested = Array(ids.reversed()) + [ids[0]]
        let resolved = await store.shotsInBackground(ids: requested)
        XCTAssertEqual(
            resolved.compactMap(\.id),
            Array(ids.reversed()),
            "批量动作必须分块解析后续页，并保持选中顺序与去重语义"
        )

        store.setFavorite(shotIDs: ids, isFavorite: true)
        let favoriteCount = try await database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM shotAttribute WHERE key = ?", arguments: [AttributeKey.favorite])
        }
        XCTAssertEqual(favoriteCount, total, "跨分页收藏必须在一个批量写路径覆盖全部 ID")

        let tail = Array(ids.suffix(25))
        store.delete(shotIDs: tail)
        let remaining = try await database.read { db in try Shot.fetchCount(db) }
        XCTAssertEqual(remaining, total - tail.count, "尚未加载页里的 ID 也必须能被批量删除")
    }
}
