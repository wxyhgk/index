import XCTest
@testable import IndexApp

/// 事件路由单测：给定坐标与状态，断言哪个 target 消费、状态怎么变。
///
/// 宿主用真实 `OverlayView`（已 conform `OverlayGestureHost`）——
/// 路由逻辑在 target 里，视图只是薄壳，所以这些测试同时覆盖了
/// 「视图鼠标方法 → router → target」的完整链路。
@MainActor
final class OverlayInteractionRouterTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // 注册表在 App 启动时才装配，测试需手动拉起
        ToolbarRegistry.registerBuiltins(into: .shared)
        CaptureActionRegistry.registerBuiltins(into: .shared, styleStore: FakeStyleStore())
    }

    // MARK: - 兜底与标注路由

    /// idle 点空白 → 没有 target 消费，兜底到选区 target，进入拖拽。
    func testIdleClickFallsThroughToSelectionTarget() {
        let view = makeView()
        view.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 50, y: 50)))
        XCTAssertEqual(view.model.phase, .dragging)
    }

    /// confirmed + 工具 + 选区内 → 标注 target 消费，开始画。
    func testToolInsideSelectionDrawsAnnotation() {
        let view = makeView()
        confirmSelection(on: view)
        view.annotation.tool = .rect
        view.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 50, y: 50)))
        XCTAssertTrue(view.annotation.isDrawing)
        XCTAssertEqual(view.model.phase, .confirmed)
    }

    /// confirmed + 工具 + 选区外 → 标注 target 消费但忽略（不重画选区）。
    func testToolOutsideSelectionIsIgnored() {
        let view = makeView()
        confirmSelection(on: view)
        view.annotation.tool = .rect
        // 选区是 (10,10)-(100,80)，工具条在选区下方；(150,5) 两者都不沾。
        view.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 150, y: 5)))
        XCTAssertFalse(view.annotation.isDrawing)
        XCTAssertEqual(view.model.phase, .confirmed)
    }

    /// confirmed + 指针模式 + 点图层 → 标注 target 消费，开始拖图层。
    func testPointerModeLayerHitBeginsMove() {
        let view = makeView()
        confirmSelection(on: view)
        // 先画一个矩形图层。选区在视图局部 (10,10)-(100,80)（左下原点），
        // 对应画布空间（左上原点）y = 300-(10..80) = 220..290；
        // 图层画在画布 (30,250)-(60,270)，换算回视图局部 y 30..50，在选区内。
        view.annotation.tool = .rect
        view.annotation.beginDraw(at: CGPoint(x: 30, y: 250))
        view.annotation.updateDraw(to: CGPoint(x: 60, y: 270))
        view.annotation.endDraw(pixelSource: { view.frozenPixels($0) })
        view.annotation.tool = nil
        view.annotation.pointerEngaged = true
        XCTAssertFalse(view.annotation.layers.isEmpty)

        // 点图层中心（不在缩放控制点上）：画布 (45,260) → 视图局部 (45, 300-260) = (45,40)。
        view.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 45, y: 40)))
        XCTAssertTrue(view.annotation.isMoving)
    }

    /// confirmed + 中性态 + 选区内 → 兜底到选区 target，进入调整。
    func testNeutralClickInsideSelectionAdjusts() {
        let view = makeView()
        confirmSelection(on: view)
        view.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 50, y: 50)))
        XCTAssertEqual(view.model.phase, .adjusting)
    }

    // MARK: - 工具条 / plain / 整窗

    /// confirmed + 点工具条控件 → 工具条 target 消费（记录按下）。
    func testToolbarHitConsumedByToolbarTarget() {
        let view = makeView()
        confirmSelection(on: view)
        view.annotation.tool = .rect
        guard let slot = view.slots.first(where: { $0.control != nil }) else {
            return XCTFail("没有工具条控件")
        }
        view.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: slot.hitFrame.midX, y: slot.hitFrame.midY)))
        XCTAssertEqual(view.pressedControlID, slot.control?.id)
    }

    /// plain 模式 + confirmed + 双击选区内 → plain target 消费，emit finish。
    func testPlainDoubleClickEmitsFinish() {
        let view = makeView(mode: .plain)
        confirmSelection(on: view)
        var finished = false
        view.onFinish = { _ in finished = true }
        view.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 50, y: 50), clickCount: 2))
        XCTAssertTrue(finished)
    }

    /// idle + ⌥ 点窗口 → 整窗 target 消费，emit 整窗捕获请求。
    func testOptionClickOnWindowEmitsFullWindow() {
        let window = WindowInfo(
            windowID: 7, pid: 1234, title: "Doc", ownerName: "TextEdit",
            frame: CGRect(x: 20, y: 20, width: 120, height: 80), layer: 0
        )
        let view = makeView(windows: [window])
        var request: WindowInfo?
        view.onFinish = { result in request = result?.windowCaptureRequest }
        view.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 60, y: 60), flags: .option))
        XCTAssertEqual(request?.windowID, 7)
    }

    // MARK: - 辅助

    /// 拖出一个选区并确认（走完整的 down → dragged → up 路由链）。
    private func confirmSelection(on view: OverlayView) {
        view.frame = CGRect(x: 0, y: 0, width: 200, height: 300)
        view.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 10, y: 10)))
        view.mouseDragged(with: mouse(.leftMouseDragged, at: CGPoint(x: 100, y: 80)))
        view.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 100, y: 80)))
        XCTAssertEqual(view.model.phase, .confirmed)
    }

    private func mouse(
        _ type: NSEvent.EventType,
        at location: CGPoint,
        clickCount: Int = 1,
        flags: NSEvent.ModifierFlags = []
    ) -> NSEvent {
        NSEvent.mouseEvent(
            with: type,
            location: location,
            modifierFlags: flags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: clickCount,
            pressure: 1
        )!
    }

    private func makeView(
        mode: SelectionMode = .capture,
        windows: [WindowInfo] = []
    ) -> OverlayView {
        // 300pt 高：选区（70）+ 双行工具条（76）+ 间隙必须放得下，
        // 否则工具条会被布局进选区内部，挡住测试点击点。
        let display = DisplayInfo(
            id: 1,
            name: "Test Display",
            frame: CGRect(x: 0, y: 0, width: 200, height: 300),
            scale: 1
        )
        let context = CGContext(
            data: nil,
            width: 200,
            height: 300,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let snapshot = DisplaySnapshot(display: display, image: context.makeImage()!)
        return OverlayView(
            model: SelectionModel(snapshot: snapshot, windows: windows),
            isPrimaryScreen: true,
            mode: mode,
            capture: FakeStyleStore(),
            annotationStyle: FakeStyleStore()
        )
    }
}