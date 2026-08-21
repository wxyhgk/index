import CoreGraphics
import Foundation
import GRDB
import XCTest
@testable import IndexApp

@MainActor
final class URLCommandRouterBrowserImportTests: XCTestCase {

    func testBrowserCommandImportsImagePreservesPageSourceAndConsumesInbox() async throws {
        let database = try DatabaseQueue()
        try AppDatabase.migrator.migrate(database)
        let libraryRoot = temporaryDirectory("library")
        let inboxRoot = temporaryDirectory("inbox")
        defer {
            try? FileManager.default.removeItem(at: libraryRoot)
            try? FileManager.default.removeItem(at: inboxRoot)
        }

        let id = UUID()
        let itemDirectory = inboxRoot.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: itemDirectory, withIntermediateDirectories: true)
        let imageURL = itemDirectory.appendingPathComponent("MR-TADF.png")
        try XCTUnwrap(ImageCodec.pngData(from: try makeImage())).write(to: imageURL)
        let metadata = BrowserImportInbox.Metadata(
            schemaVersion: 1,
            imageFile: "MR-TADF.png",
            fileName: "MR-TADF.png",
            mimeType: "image/png",
            pageURL: "https://example.test/research/article",
            pageTitle: "Research article",
            imageURL: "https://example.test/assets/molecule.png"
        )
        try JSONEncoder().encode(metadata).write(
            to: itemDirectory.appendingPathComponent("metadata.json")
        )

        let store = ShotStore(rootDirectory: libraryRoot, database: database)
        var didShowGallery = false
        let router = URLCommandRouter(
            shotStore: store,
            galleryViewModel: GalleryViewModel(store: store),
            captureCoordinator: .preview,
            imageImporter: ImageImportCoordinator(store: store),
            browserInboxRoot: inboxRoot,
            showGallery: { didShowGallery = true }
        )

        router.handle(try XCTUnwrap(URL(string: "index://import/browser?id=\(id.uuidString)")))
        await router.waitForPendingBrowserImport()

        XCTAssertEqual(store.totalCount, 1)
        store.reload()
        let shot = try XCTUnwrap(store.shots.first)
        XCTAssertEqual(shot.appName, "Microsoft Edge")
        XCTAssertEqual(shot.appBundleID, "com.microsoft.edgemac")
        XCTAssertEqual(shot.windowTitle, "MR-TADF.png")
        XCTAssertEqual(shot.sourceURL, "https://example.test/research/article")
        XCTAssertFalse(didShowGallery, "浏览器后台导入不应抢焦点或打开图库")
        XCTAssertFalse(FileManager.default.fileExists(atPath: itemDirectory.path))
        let completionURL = inboxRoot
            .appendingPathComponent(".results", isDirectory: true)
            .appendingPathComponent("\(id.uuidString.lowercased()).json")
        let completion = try JSONDecoder().decode(
            BrowserImportInbox.Completion.self,
            from: Data(contentsOf: completionURL)
        )
        XCTAssertEqual(
            completion,
            .init(ok: true, fileName: "MR-TADF.png", error: nil)
        )
    }

    func testAcceptsIndexAndLegacySchemes() throws {
        let database = try DatabaseQueue()
        try AppDatabase.migrator.migrate(database)
        let libraryRoot = temporaryDirectory("schemes")
        defer { try? FileManager.default.removeItem(at: libraryRoot) }
        let store = ShotStore(rootDirectory: libraryRoot, database: database)
        var galleryOpenCount = 0
        let router = URLCommandRouter(
            shotStore: store,
            galleryViewModel: GalleryViewModel(store: store),
            captureCoordinator: .preview,
            imageImporter: ImageImportCoordinator(store: store),
            showGallery: { galleryOpenCount += 1 }
        )

        router.handle(try XCTUnwrap(URL(string: "index://gallery")))
        router.handle(try XCTUnwrap(URL(string: "macshot://gallery")))
        router.handle(try XCTUnwrap(URL(string: "unrelated://gallery")))

        XCTAssertEqual(galleryOpenCount, 2)
    }

    private func temporaryDirectory(_ suffix: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "URLCommandRouterBrowserImportTests-\(suffix)-\(UUID().uuidString)",
                isDirectory: true
            )
    }

    private func makeImage() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: 8,
            height: 6,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.3, green: 0.6, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 6))
        return try XCTUnwrap(context.makeImage())
    }
}
