import XCTest
@testable import IndexApp

@MainActor
final class RecordingCoordinatorTests: XCTestCase {

    func testDefaultFakeStyleStoreIndexesCompletedRecording() async {
        let styleStore = FakeStyleStore()
        var indexedURLs: [URL] = []
        let coordinator = RecordingCoordinator(
            shotStore: FakeShotStore(),
            styleStore: styleStore,
            recordingAnchorSaver: { indexedURLs.append($0) },
            recorder: ScreenRecorder()
        )
        let url = URL(fileURLWithPath: "/tmp/default-recording.mp4")

        await coordinator.indexRecordingIfEnabled(at: url)

        XCTAssertTrue(styleStore.recordingSaveToLibrary)
        XCTAssertEqual(indexedURLs, [url])
    }

    func testExplicitlyDisabledLibrarySettingSkipsRecordingIndex() async {
        let styleStore = FakeStyleStore(
            recording: RecordingPrefs(
                recordSystemAudio: true,
                recordMicrophone: false,
                recordingSaveToLibrary: false
            )
        )
        var indexedURLs: [URL] = []
        let coordinator = RecordingCoordinator(
            shotStore: FakeShotStore(),
            styleStore: styleStore,
            recordingAnchorSaver: { indexedURLs.append($0) },
            recorder: ScreenRecorder()
        )

        await coordinator.indexRecordingIfEnabled(
            at: URL(fileURLWithPath: "/tmp/file-only-recording.mp4")
        )

        XCTAssertFalse(styleStore.recordingSaveToLibrary)
        XCTAssertTrue(indexedURLs.isEmpty)
    }

    func testRuntimeTerminationCleansCoordinatorOnlyOnce() {
        let recorder = ScreenRecorder()
        var stateChangeCount = 0
        var presentedErrors: [NSError] = []
        let coordinator = RecordingCoordinator(
            shotStore: FakeShotStore(),
            styleStore: FakeStyleStore(),
            runtimeFailurePresenter: { error in
                presentedErrors.append(error as NSError)
            },
            recorder: recorder
        )
        coordinator.onStateChanged = { stateChangeCount += 1 }
        let error = NSError(domain: "RecordingCoordinatorTests", code: 7)
        let event = RecordingTerminationEvent(id: UUID(), error: error)

        coordinator.handleRecorderTermination(event)
        coordinator.handleRecorderTermination(event)

        XCTAssertEqual(stateChangeCount, 1)
        XCTAssertEqual(presentedErrors.map(\.code), [7])
    }

    func testTerminationRelayEmitsOnlyFirstFailure() {
        var codes: [Int] = []
        let relay = RecordingTerminationRelay { error in
            codes.append((error as NSError).code)
        }

        relay.emit(NSError(domain: "RecordingCoordinatorTests", code: 1))
        relay.emit(NSError(domain: "RecordingCoordinatorTests", code: 2))

        XCTAssertEqual(codes, [1])
    }
}
