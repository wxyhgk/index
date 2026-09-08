import GRDB
import XCTest
@testable import IndexApp

@MainActor
final class CodeContentStoreTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodeContentStoreTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testCreatePersistsCodeTextLanguageAndKind() throws {
        let (store, database) = try makeStore()

        let shot = try store.createCodeShot(
            title: "网络请求",
            text: "let value = try await client.fetch()",
            language: "  SWIFT  "
        )

        XCTAssertEqual(shot.contentKind, ContentKind.code.rawValue)
        XCTAssertEqual(shot.primaryDisplayName, "网络请求")
        let code = try XCTUnwrap(store.codeContent(for: shot))
        XCTAssertEqual(code.language, "swift")
        XCTAssertEqual(code.text, "let value = try await client.fetch()")

        try database.read { db in
            XCTAssertEqual(try ShotContent.fetchCount(db), 1)
            XCTAssertEqual(try ContentCode.fetchCount(db), 1)
            XCTAssertEqual(try ContentMarkdown.fetchCount(db), 0)
        }
    }

    func testSaveUpdatesStableContentRowAndCanClearLanguage() throws {
        let (store, database) = try makeStore()
        let shot = try store.createCodeShot(title: "片段", text: "print(1)", language: "python")
        let firstContentID = try XCTUnwrap(try store.content(for: XCTUnwrap(shot.id))?.id)

        try store.saveContent(
            for: XCTUnwrap(shot.id),
            kind: .code,
            payload: .code("console.log(2)", language: "   "),
            updateKind: false
        )

        let updated = try XCTUnwrap(store.codeContent(for: shot))
        XCTAssertEqual(updated.contentID, firstContentID)
        XCTAssertNil(updated.language)
        XCTAssertEqual(updated.text, "console.log(2)")
        try database.read { db in
            XCTAssertEqual(try ShotContent.fetchCount(db), 1)
            XCTAssertEqual(try ContentCode.fetchCount(db), 1)
        }
    }

    func testChangingStructuredKindRemovesStaleExtensionRow() throws {
        let (store, database) = try makeStore()
        let shot = try store.createCodeShot(title: "片段", text: "print(1)", language: "python")

        try store.saveContent(
            for: XCTUnwrap(shot.id),
            kind: .markdown,
            payload: .markdown("# 已转换"),
            updateKind: true
        )

        XCTAssertNil(store.codeContent(for: shot))
        XCTAssertEqual(store.markdownSource(for: shot), "# 已转换")
        try database.read { db in
            XCTAssertEqual(try ContentCode.fetchCount(db), 0)
            XCTAssertEqual(try ContentMarkdown.fetchCount(db), 1)
        }
    }

    func testFakeStoreKeepsCodePayloadAndLanguage() throws {
        let store = FakeShotStore(rootDirectory: root)
        let shot = try store.createCodeShot(title: "测试", text: "fn main() {}", language: "RUST")

        XCTAssertEqual(
            store.codeContent(for: shot),
            ContentCode(contentID: try XCTUnwrap(shot.id), language: "rust", text: "fn main() {}")
        )

        try store.saveContent(
            for: try XCTUnwrap(shot.id),
            kind: .code,
            payload: .code("fn main() { println!(\"ok\") }", language: "rust"),
            updateKind: false
        )
        XCTAssertEqual(store.codeContent(for: shot)?.text, "fn main() { println!(\"ok\") }")
    }

    private func makeStore() throws -> (ShotStore, DatabaseQueue) {
        let database = try DatabaseQueue()
        try AppDatabase.migrator.migrate(database)
        return (ShotStore(rootDirectory: root, database: database), database)
    }
}
