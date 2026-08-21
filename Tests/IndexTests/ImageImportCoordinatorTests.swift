import CoreGraphics
import GRDB
import XCTest
@testable import IndexApp

@MainActor
final class ImageImportCoordinatorTests: XCTestCase {

    func testImportsSupportedImageAndKeepsIndependentOriginal() async throws {
        let database = try DatabaseQueue()
        try AppDatabase.migrator.migrate(database)
        let root = temporaryDirectory("library")
        let sourceRoot = temporaryDirectory("source")
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: sourceRoot)
        }

        let source = sourceRoot.appendingPathComponent("MR-TADF.png")
        let image = try makeImage(width: 7, height: 5)
        try XCTUnwrap(ImageCodec.pngData(from: image)).write(to: source)

        let store = ShotStore(rootDirectory: root, database: database)
        let importer = ImageImportCoordinator(store: store)
        let report = await importer.importImages(at: [source])

        XCTAssertEqual(report, .init(importedCount: 1, failedFileNames: []))
        XCTAssertFalse(importer.isImporting)
        XCTAssertEqual(store.totalCount, 1)

        store.reload()
        let imported = try XCTUnwrap(store.shots.first)
        XCTAssertEqual(imported.windowTitle, "MR-TADF.png")
        XCTAssertEqual(imported.primaryDisplayName, "MR-TADF.png")
        XCTAssertEqual(imported.pixelWidth, 7)
        XCTAssertEqual(imported.pixelHeight, 5)
        XCTAssertEqual(imported.scale, 1)

        try FileManager.default.removeItem(at: source)
        XCTAssertNotNil(store.originalImage(for: imported), "删掉外部文件后，图库原图仍应可读")
    }

    func testReportsUnsupportedAndCorruptFilesWithoutCreatingRows() async throws {
        let database = try DatabaseQueue()
        try AppDatabase.migrator.migrate(database)
        let root = temporaryDirectory("library")
        let sourceRoot = temporaryDirectory("source")
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: sourceRoot)
        }

        let text = sourceRoot.appendingPathComponent("notes.txt")
        let corrupt = sourceRoot.appendingPathComponent("broken.png")
        try Data("not an image".utf8).write(to: text)
        try Data("not a png".utf8).write(to: corrupt)

        let store = ShotStore(rootDirectory: root, database: database)
        let importer = ImageImportCoordinator(store: store)
        let report = await importer.importImages(at: [text, corrupt])

        XCTAssertEqual(report.importedCount, 0)
        XCTAssertEqual(report.failedFileNames, ["notes.txt", "broken.png"])
        XCTAssertEqual(store.totalCount, 0)
    }

    func testSupportedExtensionsMatchFirstReleaseScope() {
        XCTAssertTrue(ImageImportCoordinator.supports(URL(fileURLWithPath: "/tmp/a.png")))
        XCTAssertTrue(ImageImportCoordinator.supports(URL(fileURLWithPath: "/tmp/a.JPEG")))
        XCTAssertTrue(ImageImportCoordinator.supports(URL(fileURLWithPath: "/tmp/a.heic")))
        XCTAssertTrue(ImageImportCoordinator.supports(URL(fileURLWithPath: "/tmp/a.heif")))
        XCTAssertTrue(ImageImportCoordinator.supports(URL(fileURLWithPath: "/tmp/a.tiff")))
        XCTAssertTrue(ImageImportCoordinator.supports(URL(fileURLWithPath: "/tmp/a.webp")))
        XCTAssertTrue(ImageImportCoordinator.supports(URL(fileURLWithPath: "/tmp/a.gif")))
        XCTAssertTrue(ImageImportCoordinator.supports(URL(fileURLWithPath: "/tmp/a.svg")))
        XCTAssertFalse(ImageImportCoordinator.supports(URL(fileURLWithPath: "/tmp/a.pdf")))
        XCTAssertFalse(ImageImportCoordinator.supports(URL(fileURLWithPath: "/tmp/a.mp4")))
    }

    private func temporaryDirectory(_ suffix: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ImageImportCoordinatorTests-\(suffix)-\(UUID().uuidString)",
                isDirectory: true
            )
    }

    private func makeImage(width: Int, height: Int) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }
}
