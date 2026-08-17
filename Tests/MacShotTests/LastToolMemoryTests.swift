import XCTest
@testable import MacShot

/// 「记住上次使用的工具」：选过工具就回写 `lastToolID`，
/// 下次确认选区后从中性态恢复那把工具。
@MainActor
final class LastToolMemoryTests: XCTestCase {

    func testSelectingToolPersistsLastToolID() {
        let store = FakeStyleStore()
        let view = makeView(capture: store)

        view.annotation.tool = .arrow
        XCTAssertEqual(store.capture.lastToolID, "arrow")

        view.annotation.tool = .pixelate
        XCTAssertEqual(store.capture.lastToolID, "pixelate")
    }

    func testPointerDoesNotOverwriteLastToolID() {
        let store = FakeStyleStore()
        let view = makeView(capture: store)

        view.annotation.tool = .arrow
        view.annotation.tool = nil

        XCTAssertEqual(store.capture.lastToolID, "arrow")
    }

    func testConfirmingSelectionRestoresLastTool() {
        let store = FakeStyleStore()
        store.capture.lastToolID = "arrow"
        let view = makeView(capture: store)

        confirmSelection(on: view)

        XCTAssertEqual(view.annotation.tool, .arrow)
        XCTAssertFalse(view.annotation.pointerEngaged)
    }

    func testConfirmingSelectionWithoutSavedToolStaysNeutral() {
        let view = makeView()
        confirmSelection(on: view)

        XCTAssertNil(view.annotation.tool)
        XCTAssertFalse(view.annotation.pointerEngaged)
    }

    func testUnknownToolIDStaysNeutral() {
        let store = FakeStyleStore()
        store.capture.lastToolID = "tool-that-was-removed"
        let view = makeView(capture: store)

        confirmSelection(on: view)

        XCTAssertNil(view.annotation.tool)
    }

    // MARK: - 辅助

    /// 模拟一次完整的选区拖拽确认（mouseDown → mouseUp），
    /// 走 `OverlayView.mouseUp` 里 `model.endDrag()` 的恢复路径。
    private func confirmSelection(on view: OverlayView) {
        view.frame = view.bounds == .zero
            ? CGRect(x: 0, y: 0, width: 200, height: 120)
            : view.frame
        view.mouseDown(with: mouseEvent(.leftMouseDown, at: CGPoint(x: 10, y: 10)))
        view.mouseDragged(with: mouseEvent(.leftMouseDragged, at: CGPoint(x: 100, y: 80)))
        view.mouseUp(with: mouseEvent(.leftMouseUp, at: CGPoint(x: 100, y: 80)))
        XCTAssertEqual(view.model.phase, .confirmed)
    }

    private func mouseEvent(_ type: NSEvent.EventType, at location: CGPoint) -> NSEvent {
        NSEvent.mouseEvent(
            with: type,
            location: location,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )!
    }

    private func makeView(capture: FakeStyleStore? = nil) -> OverlayView {
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
            capture: capture ?? FakeStyleStore(),
            annotationStyle: FakeStyleStore()
        )
    }
}