import XCTest
@testable import IndexApp
import GRDB

final class ClipboardHistoryTests: XCTestCase {

    private var db: DatabaseQueue!
    private var store: ClipboardHistoryStore!

    override func setUp() async throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue)
        self.db = queue
        self.store = try ClipboardHistoryStore(writer: queue)
    }

    override func tearDown() async throws {
        try? db.close()
        db = nil
        store = nil
    }

    func testRecordTextAndDedup() throws {
        let added = try store.record(
            kind: .text,
            contentHash: "abc123",
            text: "hello world",
            assetPath: nil,
            summary: "hello world",
            sourceApp: "Safari"
        )
        XCTAssertTrue(added, "首次记录应新增")

        // 相同 hash 再次记录 → 去重命中，只刷新时间
        let addedAgain = try store.record(
            kind: .text,
            contentHash: "abc123",
            text: "hello world",
            assetPath: nil,
            summary: "hello world",
            sourceApp: "Safari"
        )
        XCTAssertFalse(addedAgain, "相同 hash 应去重")

        let items = try store.recent(limit: 10)
        XCTAssertEqual(items.count, 1, "去重后只有一条")
        XCTAssertEqual(items.first?.text, "hello world")
    }

    func testRecentOrdering() throws {
        try store.record(kind: .text, contentHash: "h1", text: "first", assetPath: nil, summary: "first", sourceApp: nil)
        Thread.sleep(forTimeInterval: 0.01)
        try store.record(kind: .text, contentHash: "h2", text: "second", assetPath: nil, summary: "second", sourceApp: nil)

        let items = try store.recent(limit: 10)
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items.first?.text, "second", "最新的在前")
    }

    func testSearchFilter() throws {
        try store.record(kind: .text, contentHash: "h1", text: "apple pie", assetPath: nil, summary: "apple pie", sourceApp: nil)
        try store.record(kind: .text, contentHash: "h2", text: "banana split", assetPath: nil, summary: "banana split", sourceApp: nil)

        let filtered = try store.recent(limit: 10, query: "apple")
        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered.first?.text, "apple pie")
    }

    func testClipboardFTSMigrationAndSearchStaySynchronized() throws {
        let hasTable = try db.read { database in
            try database.tableExists("clipboardHistoryFts")
        }
        XCTAssertTrue(hasTable)

        try store.record(
            kind: .text,
            contentHash: "fts-sync",
            text: "opencode installation guide",
            assetPath: nil,
            summary: "developer note",
            sourceApp: nil
        )
        let inserted = try XCTUnwrap(store.recent(limit: 1).first)
        XCTAssertEqual(try store.recent(limit: 10, query: "opencode").map(\.id), [inserted.id])

        store.rename("renamed searchable card", for: inserted)
        XCTAssertEqual(try store.recent(limit: 10, query: "searchable").map(\.id), [inserted.id])
    }

    func testStableCursorPaginationHasNoDuplicates() throws {
        for index in 0..<205 {
            try store.record(
                kind: .text,
                contentHash: "page-\(index)",
                text: "item \(index)",
                assetPath: nil,
                summary: "item \(index)",
                sourceApp: nil
            )
        }

        let first = try store.page(limit: 100)
        let firstTail = try XCTUnwrap(first.last)
        let second = try store.page(
            limit: 100,
            before: .init(capturedAt: firstTail.capturedAt, id: try XCTUnwrap(firstTail.id))
        )
        let secondTail = try XCTUnwrap(second.last)
        let third = try store.page(
            limit: 100,
            before: .init(capturedAt: secondTail.capturedAt, id: try XCTUnwrap(secondTail.id))
        )

        let ids = (first + second + third).compactMap(\.id)
        XCTAssertEqual(first.count, 100)
        XCTAssertEqual(second.count, 100)
        XCTAssertEqual(third.count, 5)
        XCTAssertEqual(Set(ids).count, 205)
    }

    func testDeleteRemovesAsset() throws {
        let data = Data("fake-png-bytes".utf8)
        let assetPath = try store.writeImageAsset(data, sha: "imgsha1")
        try store.record(
            kind: .image,
            contentHash: "imgsha1",
            text: nil,
            assetPath: assetPath,
            summary: "图片 100×100",
            sourceApp: nil
        )
        let items = try store.recent(limit: 10)
        XCTAssertEqual(items.count, 1)
        let fileURL = store.assetDirectory.appendingPathComponent(assetPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path), "图片文件应存在")

        store.delete(items[0])
        let after = try store.recent(limit: 10)
        XCTAssertEqual(after.count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path), "删除后图片文件应清理")
    }

    func testCoordinatorHashAndSummary() {
        let hash = ClipboardHistoryCoordinator.hash(Data("test".utf8))
        XCTAssertEqual(hash.count, 64, "SHA256 hex 应为 64 字符")
        XCTAssertEqual(
            hash,
            "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08"
        )

        let summary = ClipboardHistoryCoordinator.summary(for: "line one\nline two")
        XCTAssertEqual(summary, "line one", "摘要取第一行")

        let long = String(repeating: "a", count: 200)
        let longSummary = ClipboardHistoryCoordinator.summary(for: long)
        XCTAssertEqual(longSummary.count, 121, "120 字符 + 省略号")
        XCTAssertTrue(longSummary.hasSuffix("…"))
    }

    func testClipboardChangeGateSuppressesHistoryWriteBackOnlyOnce() {
        var gate = ClipboardChangeGate()

        gate.synchronize(to: 41)
        XCTAssertFalse(gate.consumeIfChanged(41), "内部写回的 changeCount 应被直接消费")
        XCTAssertTrue(gate.consumeIfChanged(42), "下一次真实的外部复制仍应进入历史")
        XCTAssertFalse(gate.consumeIfChanged(42), "同一个 changeCount 不应重复处理")
    }

    @MainActor
    func testPopupSelectionResolvesItemImmediatelyByStableID() throws {
        try store.record(
            kind: .text,
            contentHash: "selection-1",
            text: "first",
            assetPath: nil,
            summary: "first",
            sourceApp: nil
        )
        try store.record(
            kind: .text,
            contentHash: "selection-2",
            text: "second",
            assetPath: nil,
            summary: "second",
            sourceApp: nil
        )
        let items = try store.recent(limit: 10)
        let viewModel = ClipboardHistoryViewModel(store: store)
        viewModel.items = items

        viewModel.select(items[1])

        XCTAssertEqual(viewModel.selectedIndex, 1)
        XCTAssertEqual(viewModel.selectedItemID, items[1].id)
    }

    @MainActor
    func testPopupPasteQueueUsesExplicitSelectionOrder() throws {
        for index in 1...3 {
            try store.record(
                kind: .text,
                contentHash: "queue-\(index)",
                text: "text-\(index)",
                assetPath: nil,
                summary: "text-\(index)",
                sourceApp: nil
            )
        }
        let items = try store.recent(limit: 10)
        let viewModel = ClipboardHistoryViewModel(store: store)
        viewModel.items = items

        viewModel.select(items[1])
        viewModel.select(items[0], extending: true)
        viewModel.select(items[2], extending: true)

        XCTAssertEqual(viewModel.orderedSelectedIDs, [items[1].id, items[0].id, items[2].id].compactMap { $0 })
        XCTAssertEqual(viewModel.selectionOrdinal(for: items[1]), 1)
        XCTAssertEqual(viewModel.selectionOrdinal(for: items[0]), 2)
        XCTAssertEqual(viewModel.selectionOrdinal(for: items[2]), 3)

        // 取消再加入必须排到队尾，而不是回到列表里的原始位置。
        viewModel.select(items[0], extending: true)
        viewModel.select(items[0], extending: true)
        XCTAssertEqual(viewModel.orderedSelectedIDs, [items[1].id, items[2].id, items[0].id].compactMap { $0 })
    }

    func testQueuedTextUsesNewlineAndKeepsOrder() {
        XCTAssertEqual(
            ClipboardHistoryViewModel.joinedTexts(["first", "second", "third"]),
            "first\nsecond\nthird"
        )
    }

    @MainActor
    func testPasteQueueSurvivesSearchAndAppendsResult() throws {
        try store.record(
            kind: .text,
            contentHash: "before-search",
            text: "chosen before search",
            assetPath: nil,
            summary: "chosen before search",
            sourceApp: nil
        )
        try store.record(
            kind: .text,
            contentHash: "search-result",
            text: "needle result",
            assetPath: nil,
            summary: "needle result",
            sourceApp: nil
        )
        let allItems = try store.recent(limit: 10)
        let first = try XCTUnwrap(allItems.first { $0.contentHash == "before-search" })
        let result = try XCTUnwrap(allItems.first { $0.contentHash == "search-result" })
        let viewModel = ClipboardHistoryViewModel(store: store)
        viewModel.items = allItems
        viewModel.select(first)

        // 搜索只替换候选列表，已选条目快照不能随之消失。
        viewModel.query = "needle"
        viewModel.items = [result]
        viewModel.selectedIndex = 0
        viewModel.setContinuousSelectionEnabled(true)
        viewModel.select(
            result,
            continuingQueue: viewModel.isContinuousSelectionEnabled
        )

        XCTAssertEqual(viewModel.orderedSelectedIDs, [first.id, result.id].compactMap { $0 })
        XCTAssertEqual(viewModel.pasteQueueItems.map(\.contentHash), ["before-search", "search-result"])
        XCTAssertEqual(viewModel.selectionOrdinal(for: result), 2)
    }

    @MainActor
    func testContinuousSelectionModeExplicitlyControlsAppend() throws {
        for index in 1...2 {
            try store.record(
                kind: .text,
                contentHash: "mode-\(index)",
                text: "mode-\(index)",
                assetPath: nil,
                summary: "mode-\(index)",
                sourceApp: nil
            )
        }
        let items = try store.recent(limit: 10)
        let viewModel = ClipboardHistoryViewModel(store: store)
        viewModel.items = items

        viewModel.select(items[0])
        viewModel.select(
            items[1],
            continuingQueue: viewModel.isContinuousSelectionEnabled
        )
        XCTAssertEqual(viewModel.orderedSelectedIDs, [items[1].id].compactMap { $0 })

        viewModel.select(items[0])
        viewModel.setContinuousSelectionEnabled(true)
        viewModel.select(
            items[1],
            continuingQueue: viewModel.isContinuousSelectionEnabled
        )
        XCTAssertEqual(viewModel.orderedSelectedIDs, [items[0].id, items[1].id].compactMap { $0 })

        // 连续模式再次点击同一张卡片就是取消，不需要去左侧点移除。
        viewModel.select(
            items[1],
            continuingQueue: viewModel.isContinuousSelectionEnabled
        )
        XCTAssertEqual(viewModel.orderedSelectedIDs, [items[0].id].compactMap { $0 })
        XCTAssertNil(viewModel.selectionOrdinal(for: items[1]))

        viewModel.setContinuousSelectionEnabled(false)
        XCTAssertEqual(viewModel.orderedSelectedIDs, [items[1].id].compactMap { $0 })
    }
}
