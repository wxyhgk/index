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
}
