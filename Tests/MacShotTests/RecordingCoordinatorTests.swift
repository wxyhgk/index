import XCTest
@testable import MacShot

@MainActor
final class RecordingCoordinatorTests: XCTestCase {

    func testDefaultFakeStyleStoreIndexesCompletedRecording() async {
        let styleStore = FakeStyleStore()
        var indexedURLs: [URL] = []
        let coordinator = RecordingCoordinator(
            shotStore: FakeShotStore(),
            styleStore: styleStore,
            recordingAnchorSaver: { indexedURLs.append($0) }
        )
        let url = URL(fileURLWithPath: "/tmp/default-recording.mp4")

        await coordinator.indexRecordingIfEnabled(at: url)

        XCTAssertTrue(styleStore.recordingSaveToLibrary)
        XCTAssertEqual(indexedURLs, [url])
    }

    func testExplicitlyDisabledLibrarySettingSkipsRecordingIndex() async {
        let styleStore = FakeStyleStore(recordingSaveToLibrary: false)
        var indexedURLs: [URL] = []
        let coordinator = RecordingCoordinator(
            shotStore: FakeShotStore(),
            styleStore: styleStore,
            recordingAnchorSaver: { indexedURLs.append($0) }
        )

        await coordinator.indexRecordingIfEnabled(
            at: URL(fileURLWithPath: "/tmp/file-only-recording.mp4")
        )

        XCTAssertFalse(styleStore.recordingSaveToLibrary)
        XCTAssertTrue(indexedURLs.isEmpty)
    }
}
