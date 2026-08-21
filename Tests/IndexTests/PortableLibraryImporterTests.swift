import CoreGraphics
import Foundation
import GRDB
import XCTest
@testable import IndexApp

@MainActor
final class PortableLibraryImporterTests: XCTestCase {
    private var sourceRoot: URL!
    private var targetRoot: URL!
    private var exportRoot: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImporterTests-\(UUID().uuidString)", isDirectory: true)
        sourceRoot = base.appendingPathComponent("source", isDirectory: true)
        targetRoot = base.appendingPathComponent("target", isDirectory: true)
        exportRoot = base.appendingPathComponent("exports", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: targetRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: exportRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        let base = sourceRoot?.deletingLastPathComponent()
        if let base {
            try? FileManager.default.removeItem(at: base)
        }
    }

    // MARK: - 导出包含剪贴板的包

    func testExportIncludesClipboardItems() async throws {
        let (store, database) = try makeStore(root: sourceRoot)
        _ = try store.save(image: makeImage(gray: 0.3), metadata: CaptureMetadata())

        // 添加剪贴板文本条目
        try await database.write { db in
            var textItem = ClipboardHistoryItem(
                id: nil, kind: .text,
                contentHash: String(repeating: "a", count: 64),
                text: "hello world", assetPath: nil,
                summary: "hello world", sourceApp: "Safari",
                pinned: false, capturedAt: Date(), lastUsedAt: nil,
                title: nil, isFavorite: false
            )
            try textItem.insert(db)
        }

        // 添加剪贴板图片条目
        let imageHash = String(repeating: "b", count: 64)
        try await database.write { db in
            var imageItem = ClipboardHistoryItem(
                id: nil, kind: .image,
                contentHash: imageHash,
                text: nil, assetPath: "\(imageHash).png",
                summary: "clipboard image", sourceApp: "Safari",
                pinned: false, capturedAt: Date(), lastUsedAt: nil,
                title: nil, isFavorite: false
            )
            try imageItem.insert(db)
        }
        // 写入图片文件
        let imageFile = clipboardDir(for: sourceRoot).appendingPathComponent("\(imageHash).png")
        try Data("fake-png".utf8).write(to: imageFile)

        let destination = exportRoot.appendingPathComponent("WithClipboard.indexlibrary")
        _ = try await store.exportPortableLibrary(to: destination)

        let manifestData = try Data(contentsOf: destination.appendingPathComponent("manifest.json"))
        let manifest = try PortableLibraryCoding.makeDecoder()
            .decode(PortableLibraryManifest.self, from: manifestData)

        XCTAssertEqual(manifest.formatVersion, 2)
        XCTAssertEqual(manifest.clipboard.count, 2)

        let textItem = try XCTUnwrap(manifest.clipboard.first { $0.kind == "text" })
        XCTAssertEqual(textItem.text, "hello world")
        XCTAssertNil(textItem.asset)

        let imageItem = try XCTUnwrap(manifest.clipboard.first { $0.kind == "image" })
        XCTAssertNotNil(imageItem.asset)
        XCTAssertTrue(imageItem.asset!.relativePath.hasPrefix("clipboard/"))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent(imageItem.asset!.relativePath).path
        ))
    }

    // MARK: - 导入到空库

    func testImportIntoEmptyLibrary() async throws {
        // 源库：1 张截图 + 1 个专题集 + 1 条剪贴板
        let (sourceStore, sourceDB) = try makeStore(root: sourceRoot)
        let shot = try sourceStore.save(image: makeImage(gray: 0.4), metadata: CaptureMetadata())
        let shotID = try XCTUnwrap(shot.id)
        sourceStore.setFavorite(shotIDs: [shotID], isFavorite: true)
        sourceStore.addTag(shotID: shotID, "测试")

        let collection = try sourceStore.createCollection(name: "测试集", note: "备注")
        try sourceStore.addToCollection(
            shotIDs: [shotID],
            collectionID: try XCTUnwrap(collection.id)
        )

        try await sourceDB.write { db in
            var item = ClipboardHistoryItem(
                id: nil, kind: .text,
                contentHash: String(repeating: "c", count: 64),
                text: "import me", assetPath: nil,
                summary: "import me", sourceApp: "Terminal",
                pinned: false, capturedAt: Date(), lastUsedAt: nil,
                title: nil, isFavorite: false
            )
            try item.insert(db)
        }

        // 导出
        let destination = exportRoot.appendingPathComponent("Test.indexlibrary")
        _ = try await sourceStore.exportPortableLibrary(to: destination)

        // 目标库：空
        let (targetStore, targetDB) = try makeStore(root: targetRoot)
        let importer = PortableLibraryImporter(writer: targetDB, rootDirectory: targetRoot)
        let report = try await importer.importLibrary(at: destination)

        XCTAssertEqual(report.shotsImported, 1)
        XCTAssertEqual(report.shotsSkipped, 0)
        XCTAssertEqual(report.collectionsImported, 1)
        XCTAssertEqual(report.clipboardImported, 1)

        // 验证目标库数据
        let targetShots = try await targetDB.read { db in try Shot.fetchAll(db) }
        XCTAssertEqual(targetShots.count, 1)
        XCTAssertEqual(targetShots.first?.sha256, shot.sha256)

        let targetCollections = try await targetDB.read { db in try ShotCollection.fetchAll(db) }
        XCTAssertEqual(targetCollections.count, 1)
        XCTAssertEqual(targetCollections.first?.name, "测试集")

        let targetClipboard = try await targetDB.read { db in try ClipboardHistoryItem.fetchAll(db) }
        XCTAssertEqual(targetClipboard.count, 1)
        XCTAssertEqual(targetClipboard.first?.text, "import me")

        // 验证原图文件已复制
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: targetRoot.appendingPathComponent("originals/\(shot.sha256).png").path
        ))
    }

    // MARK: - 去重：导入到已有部分数据的库

    func testImportDeduplicatesByContentHash() async throws {
        // 源库和目标库共享同一张截图（相同 sha256）
        let (sourceStore, _) = try makeStore(root: sourceRoot)
        _ = try sourceStore.save(image: makeImage(gray: 0.5), metadata: CaptureMetadata())

        let (targetStore, targetDB) = try makeStore(root: targetRoot)
        // 目标库已有相同 sha256 的截图
        _ = try targetStore.save(image: makeImage(gray: 0.5), metadata: CaptureMetadata())

        let destination = exportRoot.appendingPathComponent("Dedup.indexlibrary")
        _ = try await sourceStore.exportPortableLibrary(to: destination)

        let importer = PortableLibraryImporter(writer: targetDB, rootDirectory: targetRoot)
        let report = try await importer.importLibrary(at: destination)

        XCTAssertEqual(report.shotsImported, 0)
        XCTAssertEqual(report.shotsSkipped, 1)

        // 目标库仍然只有 1 张截图
        let count = try await targetDB.read { db in try Shot.fetchCount(db) }
        XCTAssertEqual(count, 1)
    }

    // MARK: - 幂等：重复导入

    func testImportIsIdempotent() async throws {
        let (sourceStore, sourceDB) = try makeStore(root: sourceRoot)
        _ = try sourceStore.save(image: makeImage(gray: 0.6), metadata: CaptureMetadata())
        let collection = try sourceStore.createCollection(name: "幂等集", note: "")

        try await sourceDB.write { db in
            var item = ClipboardHistoryItem(
                id: nil, kind: .text,
                contentHash: String(repeating: "d", count: 64),
                text: "idempotent", assetPath: nil,
                summary: "idempotent", sourceApp: "Safari",
                pinned: false, capturedAt: Date(), lastUsedAt: nil,
                title: nil, isFavorite: false
            )
            try item.insert(db)
        }

        let destination = exportRoot.appendingPathComponent("Idempotent.indexlibrary")
        _ = try await sourceStore.exportPortableLibrary(to: destination)

        let (targetStore, targetDB) = try makeStore(root: targetRoot)
        let importer = PortableLibraryImporter(writer: targetDB, rootDirectory: targetRoot)

        // 第一次导入
        let first = try await importer.importLibrary(at: destination)
        XCTAssertEqual(first.shotsImported, 1)
        XCTAssertEqual(first.clipboardImported, 1)

        // 第二次导入：全部跳过
        let second = try await importer.importLibrary(at: destination)
        XCTAssertEqual(second.shotsImported, 0)
        XCTAssertEqual(second.shotsSkipped, 1)
        XCTAssertEqual(second.clipboardImported, 0)
        XCTAssertEqual(second.clipboardSkipped, 1)
        XCTAssertEqual(second.collectionsImported, 0)
        XCTAssertEqual(second.collectionsMerged, 1)

        // 数据量不变
        let shotCount = try await targetDB.read { db in try Shot.fetchCount(db) }
        XCTAssertEqual(shotCount, 1)
        let clipboardCount = try await targetDB.read { db in try ClipboardHistoryItem.fetchCount(db) }
        XCTAssertEqual(clipboardCount, 1)
    }

    // MARK: - 无效包

    func testImportRejectsInvalidPackage() async throws {
        let (_, targetDB) = try makeStore(root: targetRoot)
        let importer = PortableLibraryImporter(writer: targetDB, rootDirectory: targetRoot)

        // 空目录
        let emptyDir = exportRoot.appendingPathComponent("Empty")
        try FileManager.default.createDirectory(at: emptyDir, withIntermediateDirectories: true)
        do {
            _ = try await importer.importLibrary(at: emptyDir)
            XCTFail("Expected missingManifest")
        } catch let error as PortableLibraryImporter.ImportError {
            XCTAssertEqual(error, .missingManifest)
        }

        // 非便携图库包
        let wrongDir = exportRoot.appendingPathComponent("Wrong")
        try FileManager.default.createDirectory(at: wrongDir, withIntermediateDirectories: true)
        let wrongManifest = """
        {"format": "com.other.app", "formatVersion": 1}
        """
        try Data(wrongManifest.utf8).write(to: wrongDir.appendingPathComponent("manifest.json"))
        do {
            _ = try await importer.importLibrary(at: wrongDir)
            XCTFail("Expected notAPortableLibrary")
        } catch let error as PortableLibraryImporter.ImportError {
            guard case .notAPortableLibrary = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    // MARK: - 辅助

    private func makeStore(root: URL) throws -> (ShotStore, DatabaseQueue) {
        let database = try DatabaseQueue()
        try AppDatabase.migrator.migrate(database)
        return (ShotStore(rootDirectory: root, database: database), database)
    }

    private func clipboardDir(for root: URL) -> URL {
        let dir = root.appendingPathComponent("clipboard", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeImage(gray: CGFloat) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: 8,
            height: 8,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: gray, green: gray, blue: gray, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        return try XCTUnwrap(context.makeImage())
    }
}
