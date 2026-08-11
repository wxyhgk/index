import CoreGraphics
import XCTest
@testable import MacShot

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
            isPrimaryScreen: true
        )
    }
}
