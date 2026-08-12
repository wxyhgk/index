import CoreGraphics
import GRDB
import XCTest
@testable import MacShot

@MainActor
final class GalleryViewModelTests: XCTestCase {

    private func makeSubject() throws -> (GalleryViewModel, ShotStore, URL) {
        let database = try DatabaseQueue()
        try AppDatabase.migrator.migrate(database)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GalleryViewModelTests-\(UUID().uuidString)")
        let store = ShotStore(rootDirectory: root, database: database)
        return (GalleryViewModel(store: store), store, root)
    }

    func testReloadUsesViewModelQueryWithoutPuttingUIStateInStore() async throws {
        let (viewModel, store, root) = try makeSubject()
        defer { try? FileManager.default.removeItem(at: root) }

        var recordingMetadata = CaptureMetadata()
        recordingMetadata.windowTitle = "共同查询词 录屏"
        let recording = try store.save(image: image(gray: 0.2), metadata: recordingMetadata)
        try store.attachRecording(at: URL(fileURLWithPath: "/tmp/test.mp4"), to: recording)

        var screenshotMetadata = CaptureMetadata()
        screenshotMetadata.windowTitle = "共同查询词 截图"
        _ = try store.save(image: image(gray: 0.8), metadata: screenshotMetadata)

        viewModel.searchText = "共同查询词"
        viewModel.filter = .recordings
        viewModel.reload()

        XCTAssertEqual(viewModel.displayShots.compactMap(\.id), [recording.id])
        let matchingIDs = await viewModel.allMatchingIDs()
        XCTAssertEqual(matchingIDs, [recording.id].compactMap { $0 })
    }

    func testResetPreservesFixedDestinationBoundaryAndClearsSemanticModeResultState() throws {
        let (viewModel, _, root) = try makeSubject()
        defer { try? FileManager.default.removeItem(at: root) }

        viewModel.searchText = "old query"
        viewModel.filter = .favorites
        viewModel.semanticMode = true

        viewModel.reset(to: .recordings)

        XCTAssertEqual(viewModel.searchText, "")
        XCTAssertEqual(viewModel.filter, .recordings)
        XCTAssertTrue(viewModel.semanticMode, "清空临时结果不应擅自切换用户选择的搜索模式")
        XCTAssertNil(viewModel.semanticResults)
        XCTAssertFalse(viewModel.isSemanticSearching)
    }

    func testAllMatchingIDsUsesCurrentViewModelStateRatherThanLastLoadedStoreSnapshot() async throws {
        let (viewModel, store, root) = try makeSubject()
        defer { try? FileManager.default.removeItem(at: root) }

        let first = try store.save(image: image(gray: 0.1), metadata: CaptureMetadata())
        let second = try store.save(image: image(gray: 0.9), metadata: CaptureMetadata())
        store.toggleFavorite(second)
        store.reload(query: "", filter: .all)

        viewModel.filter = .favorites
        let ids = await viewModel.allMatchingIDs()

        XCTAssertEqual(ids, [second.id].compactMap { $0 })
        XCTAssertNotEqual(ids, [first.id, second.id].compactMap { $0 })
    }

    private func image(gray: CGFloat) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: 4,
            height: 4,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: gray, green: gray, blue: gray, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        return try XCTUnwrap(context.makeImage())
    }
}
