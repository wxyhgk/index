import XCTest
import GRDB
import CoreGraphics
@testable import MacShot

@MainActor
final class GalleryContentScopeTests: XCTestCase {

    func testRecordingsScopeDoesNotTreatItsFixedFilterAsClearable() {
        let scope = GalleryContentScope.recordings

        XCTAssertFalse(scope.hasClearableState(
            searchText: "",
            filter: .recordings,
            hasSemanticResults: false
        ))
        XCTAssertTrue(scope.hasClearableState(
            searchText: "waterfall",
            filter: .recordings,
            hasSemanticResults: false
        ))
        XCTAssertTrue(scope.hasClearableState(
            searchText: "",
            filter: .recordings,
            hasSemanticResults: true
        ))
    }

    func testClearingRecordingsSearchPreservesDestinationFilter() throws {
        let database = try DatabaseQueue()
        try AppDatabase.migrator.migrate(database)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GalleryContentScopeTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ShotStore(rootDirectory: root, database: database)
        store.filter = .recordings
        store.searchText = "query"

        GalleryContentScope.recordings.clearTransientState(in: store)

        XCTAssertEqual(store.filter, .recordings)
        XCTAssertEqual(store.searchText, "")
    }

    func testCollectionScopePreservesItsFixedBoundaryWhenClearingSearch() throws {
        let database = try DatabaseQueue()
        try AppDatabase.migrator.migrate(database)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GalleryContentScopeTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ShotStore(rootDirectory: root, database: database)
        let scope = GalleryContentScope.collection(id: 42, title: "MR-TADF 分子")
        store.filter = .collection(42)
        store.searchText = "query"

        scope.clearTransientState(in: store)

        XCTAssertEqual(store.filter, .collection(42))
        XCTAssertEqual(store.searchText, "")
        XCTAssertFalse(scope.hasClearableState(
            searchText: "", filter: .collection(42), hasSemanticResults: false
        ))
    }

    func testExactSearchRemainsInsideRecordingsScope() throws {
        let database = try DatabaseQueue()
        try AppDatabase.migrator.migrate(database)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GalleryContentScopeTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ShotStore(rootDirectory: root, database: database)

        var recordingMetadata = CaptureMetadata()
        recordingMetadata.windowTitle = "共同查询词 录屏"
        let recording = try store.save(image: image(gray: 0.2), metadata: recordingMetadata)
        store.writeAttribute(
            shotID: try XCTUnwrap(recording.id),
            key: AttributeKey.recordingPath,
            value: .data(Data("/tmp/recording.mp4".utf8), searchableText: nil)
        )

        var screenshotMetadata = CaptureMetadata()
        screenshotMetadata.windowTitle = "共同查询词 截图"
        let screenshot = try store.save(image: image(gray: 0.8), metadata: screenshotMetadata)

        store.filter = .recordings
        store.searchText = "共同查询词"
        store.reload()

        XCTAssertEqual(store.shots.compactMap(\.id), [recording.id])
        XCTAssertFalse(store.shots.compactMap(\.id).contains(try XCTUnwrap(screenshot.id)))
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
