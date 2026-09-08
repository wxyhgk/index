import CoreGraphics
import XCTest
@testable import IndexApp

@MainActor
final class EditorModelSaveTests: XCTestCase {

    func testFailedSaveKeepsBaselinePendingChangesAndFailureState() {
        let subject = makeSubject(failuresRemaining: 1)
        subject.model.annotation.layers.append(makeLayer())

        XCTAssertFalse(subject.model.flushSave())

        XCTAssertTrue(subject.model.baselineLayers.isEmpty)
        XCTAssertTrue(subject.model.hasPendingChanges)
        guard case .failed(let message) = subject.model.saveState else {
            return XCTFail("写入失败后必须保留 failed 状态")
        }
        XCTAssertTrue(message.contains("测试写入失败"))
        XCTAssertEqual(subject.persistence.appendAttempts, 1)
    }

    func testRetryAfterFailureAdvancesBaselineOnlyAfterSuccess() {
        let subject = makeSubject(failuresRemaining: 1)
        let layer = makeLayer()
        subject.model.annotation.layers.append(layer)

        XCTAssertFalse(subject.model.flushSave())
        XCTAssertTrue(subject.model.hasPendingChanges)

        subject.model.retrySave()

        XCTAssertEqual(subject.model.baselineLayers, [layer])
        XCTAssertFalse(subject.model.hasPendingChanges)
        XCTAssertTrue(subject.model.hasSavedSuccessfully)
        XCTAssertEqual(subject.persistence.appendAttempts, 2)
        XCTAssertEqual(subject.model.revisions.count, 2)
    }

    func testReturnToGalleryIsBlockedUntilPendingChangesSave() {
        var returnCount = 0
        let commands = makeCommands(returnToGallery: { returnCount += 1 })
        let subject = makeSubject(failuresRemaining: 1, commands: commands)
        subject.model.annotation.layers.append(makeLayer())

        XCTAssertFalse(subject.model.requestReturnToGallery())
        XCTAssertEqual(returnCount, 0)
        XCTAssertTrue(subject.model.hasPendingChanges)

        XCTAssertTrue(subject.model.requestReturnToGallery())
        XCTAssertEqual(returnCount, 1)
        XCTAssertFalse(subject.model.hasPendingChanges)
    }

    func testHistorySwitchDoesNotReplaceCanvasWhenSaveFails() {
        let oldLayer = makeLayer(x: 1)
        let latestLayer = makeLayer(x: 2)
        let shot = makeShot()
        let persistence = TestEditorPersistence(
            shotID: shot.id!,
            revisionLayers: [[], [oldLayer], [latestLayer]],
            failuresRemaining: 1
        )
        let model = EditorModel(
            shot: shot,
            store: persistence,
            styleStore: FakeStyleStore(),
            pageCommands: makeCommands()
        )
        model.load()
        let pendingLayer = makeLayer(x: 3)
        model.annotation.layers.append(pendingLayer)

        XCTAssertFalse(model.switchToRevision(at: 0))
        XCTAssertEqual(model.loadedRevisionIndex, 2)
        XCTAssertTrue(model.annotation.layers.elements.contains(pendingLayer))
        XCTAssertTrue(model.hasPendingChanges)

        XCTAssertTrue(model.switchToRevision(at: 0))
        XCTAssertEqual(model.loadedRevisionIndex, 0)
        XCTAssertTrue(model.annotation.layers.isEmpty)
    }

    func testInvalidHistoryIndexDoesNotTriggerSave() {
        let subject = makeSubject(failuresRemaining: 1)
        subject.model.annotation.layers.append(makeLayer())

        XCTAssertFalse(subject.model.switchToRevision(at: 99))

        XCTAssertEqual(subject.persistence.appendAttempts, 0)
        XCTAssertTrue(subject.model.hasPendingChanges)
        XCTAssertEqual(subject.model.saveState, .idle)
    }

    func testSessionRelayPropagatesSaveFailure() {
        let relay = EditorSessionRelay()
        relay.install(shotID: 7) { false }

        XCTAssertFalse(relay.flush(shotID: 7))
    }

    private func makeSubject(
        failuresRemaining: Int,
        commands: GalleryPageCommands? = nil
    ) -> (model: EditorModel, persistence: TestEditorPersistence) {
        let shot = makeShot()
        let persistence = TestEditorPersistence(
            shotID: shot.id!,
            revisionLayers: [[]],
            failuresRemaining: failuresRemaining
        )
        let model = EditorModel(
            shot: shot,
            store: persistence,
            styleStore: FakeStyleStore(),
            pageCommands: commands ?? makeCommands()
        )
        model.load()
        return (model, persistence)
    }

    private func makeShot() -> Shot {
        Shot(
            id: 42,
            sha256: "editor-save-test",
            capturedAt: Date(timeIntervalSince1970: 1_000),
            pixelWidth: 8,
            pixelHeight: 8,
            scale: 2,
            appName: "Tests",
            appBundleID: nil,
            appVersion: nil,
            appBuild: nil,
            windowTitle: nil,
            sourceURL: nil,
            displayID: nil,
            displayName: nil,
            regionX: 0,
            regionY: 0,
            regionW: 8,
            regionH: 8,
            ocrText: nil
        )
    }

    private func makeLayer(x: Double = 0) -> Layer {
        Layer(kind: .rect, rect: LRect(x: x, y: 0, w: 4, h: 4))
    }

    private func makeCommands(
        returnToGallery: @escaping @MainActor () -> Void = {}
    ) -> GalleryPageCommands {
        GalleryPageCommands(
            openEditor: { _ in },
            openMarkdownEditor: { _ in },
            openCodeEditor: { _ in },
            openSettings: {},
            returnToGallery: returnToGallery,
            presentQuickLook: {},
            selectOnly: { _ in },
            clearTextFocus: {},
            hostWindow: { nil },
            performRecordingPrimary: { _, _ in }
        )
    }
}

@MainActor
private final class TestEditorPersistence: EditorPersistence {
    private let image: CGImage
    private var storedRevisions: [Revision]
    private var nextRevisionID: Int64 = 10_000
    var failuresRemaining: Int
    private(set) var appendAttempts = 0

    init(shotID: Int64, revisionLayers: [[Layer]], failuresRemaining: Int) {
        image = CGContext(
            data: nil,
            width: 8,
            height: 8,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!.makeImage()!
        self.failuresRemaining = failuresRemaining
        storedRevisions = revisionLayers.enumerated().map { index, layers in
            var revision = Revision.make(
                shotID: shotID,
                parentID: index == 0 ? nil : Int64(index),
                layers: layers,
                note: index == 0 ? "原始" : "编辑"
            )
            revision.id = Int64(index + 1)
            return revision
        }
    }

    func originalImage(for shot: Shot) -> CGImage? { image }

    func revisions(for shot: Shot) -> [Revision] { storedRevisions }

    func appendEditorRevision(
        shot: Shot,
        layers: Layers<ImageSpace>,
        note: String?
    ) throws -> Revision {
        appendAttempts += 1
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            throw TestWriteError.failed
        }
        var revision = Revision.make(
            shotID: shot.id!,
            parentID: storedRevisions.last?.id,
            layers: layers.persisted,
            note: note
        )
        revision.id = nextRevisionID
        nextRevisionID += 1
        storedRevisions.append(revision)
        return revision
    }

    private enum TestWriteError: LocalizedError {
        case failed
        var errorDescription: String? { "测试写入失败" }
    }
}
