import XCTest
@testable import IndexApp

/// 「确认选区后工具回到中性」（2026-08-20 起的行为）：
/// 不再恢复上次使用的工具 —— 每次截图确认后都是箭头状态，
/// 拖拽只调整选区；要画标注就再点一次工具按钮或按快捷键。
@MainActor
final class LastToolMemoryTests: XCTestCase {

    func testConfirmingSelectionKeepsToolNeutral() {
        let view = makeView()
        confirmSelection(on: view)

        XCTAssertNil(view.annotation.tool)
        XCTAssertFalse(view.annotation.pointerEngaged)
    }

    func testConfirmingSelectionDoesNotRestoreSavedToolID() {
        // 偏好里存着旧工具 id（历史版本写的），确认选区也不该把它捡回来。
        let store = FakeStyleStore()
        store.capture.lastToolID = "arrow"
        let view = makeView(capture: store)

        confirmSelection(on: view)

        XCTAssertNil(view.annotation.tool)
        XCTAssertFalse(view.annotation.pointerEngaged)
    }

    // MARK: - 辅助

    /// 模拟一次完整的选区拖拽确认（mouseDown → mouseUp），
    /// 走 `OverlayView.mouseUp` 里 `model.endDrag()` 的收尾路径。
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