import CoreGraphics
import XCTest
@testable import IndexApp

@MainActor
final class OverlayKeyboardTests: XCTestCase {

    func testFirstEscapeLeavesEditingAndSecondCancelsCapture() {
        let view = makeView()
        view.annotation.tool = .rect
        view.focusedControlID = "tool.rect"

        var finishCount = 0
        var resultWasNil = false
        view.onFinish = { result in
            finishCount += 1
            resultWasNil = result == nil
        }

        view.cancelFromEscape()

        XCTAssertEqual(finishCount, 0)
        XCTAssertNil(view.annotation.tool)
        XCTAssertFalse(view.annotation.pointerEngaged)
        XCTAssertNil(view.focusedControlID)

        view.cancelFromEscape()

        XCTAssertEqual(finishCount, 1)
        XCTAssertTrue(resultWasNil)
    }

    func testNeutralCaptureStillCancelsWithOneEscape() {
        let view = makeView()
        var finishCount = 0
        view.onFinish = { result in
            XCTAssertNil(result)
            finishCount += 1
        }

        view.cancelFromEscape()

        XCTAssertEqual(finishCount, 1)
    }

    func testPointerEditingAlsoUsesTwoEscapeLevels() {
        let view = makeView()
        view.annotation.pointerEngaged = true

        var finishCount = 0
        view.onFinish = { _ in finishCount += 1 }

        view.cancelFromEscape()
        XCTAssertEqual(finishCount, 0)
        XCTAssertFalse(view.annotation.pointerEngaged)

        view.cancelFromEscape()
        XCTAssertEqual(finishCount, 1)
    }

    func testShiftCOnConfirmedSelectionEmitsCopyText() {
        let view = makeView()
        view.model.beginDrag(at: CGPoint(x: 10, y: 10))
        view.model.updateDrag(to: CGPoint(x: 100, y: 80))
        XCTAssertTrue(view.model.endDrag())

        var capturedActionID: String?
        view.onFinish = { result in
            capturedActionID = result?.actionID
        }

        let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .shift,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "C",
            charactersIgnoringModifiers: "c",
            isARepeat: false,
            keyCode: KeyCode.c
        )
        guard let event else { return XCTFail("构造 ⇧C 事件失败") }
        view.keyDown(with: event)

        XCTAssertEqual(capturedActionID, ActionID.copyText)
    }

    private func makeView() -> OverlayView {
        let display = DisplayInfo(
            id: 1,
            name: "Test Display",
            frame: CGRect(x: 0, y: 0, width: 200, height: 120),
            scale: 1
        )
        let context = CGContext(
            data: nil,
            width: 200,
            height: 120,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let snapshot = DisplaySnapshot(display: display, image: context.makeImage()!)
        return OverlayView(
            model: SelectionModel(snapshot: snapshot, windows: []),
            isPrimaryScreen: true,
            capture: FakeStyleStore(),
            annotationStyle: FakeStyleStore()
        )
    }
}
