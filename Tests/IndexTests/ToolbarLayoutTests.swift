import XCTest
@testable import IndexApp

/// 工具条布局的纯函数安全网：无样式时单行，有样式时双行，命中与绘制同源。
@MainActor
final class ToolbarLayoutTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // 注册表在 App 启动时才装配，测试需手动拉起
        ToolbarRegistry.registerBuiltins(into: .shared)
        CaptureActionRegistry.registerBuiltins(into: .shared, styleStore: FakeStyleStore())
    }

    private func context(
        tool: AnnotationTool?,
        executingActions: Set<String> = []
    ) -> ToolbarContext {
        let state = AnnotationState(styleStore: FakeStyleStore())
        state.tool = tool
        // 中性态外，确保有工具时 styleAxes 非空才触发双行
        return ToolbarContext(
            annotation: state,
            scope: .capture,
            perform: { _ in },
            isActionExecuting: { executingActions.contains($0) }
        )
    }

    func testSingleRowWhenNoStyle() {
        // 指针中性态：tool == nil 且 pointerEngaged == false → styleAxes == [] → 单行
        let state = AnnotationState(styleStore: FakeStyleStore())
        state.tool = nil
        state.pointerEngaged = false
        let ctx = ToolbarContext(annotation: state, scope: .capture, perform: { _ in })
        let size = ToolbarLayout.blockSize(ctx)
        // 单行高即 rowHeight，未出现则宽为 0，断言高为单行
        if size.width > 0 {
            XCTAssertEqual(size.height, ToolbarLayout.rowHeight, "无样式时应为单行")
        } else {
            // 指针中性态下工具条可能空（无可见控件），允许 0
            XCTAssertEqual(size, .zero)
        }
    }

    func testTwoRowsWhenToolHasStyle() {
        // 矩形工具声明 color+width，最少双行
        let ctx = context(tool: .rect)
        let size = ToolbarLayout.blockSize(ctx)
        XCTAssertGreaterThan(size.width, 0, "矩形工具下工具条应有宽度")
        XCTAssertEqual(size.height, ToolbarLayout.rowHeight * 2 + ToolbarLayout.interRowGap, "有样式时应为双行")
    }

    func testBlockWidthIsMaxOfRows() {
        let ctx = context(tool: .rect)
        let size = ToolbarLayout.blockSize(ctx)
        let slots = ToolbarLayout.slots(origin: .zero, context: ctx)
        let rows = ToolbarLayout.rowFrames(of: slots)
        XCTAssertEqual(rows.count, 2, "有样式时应为两行")
        let maxWidth = rows.map(\.width).max() ?? 0
        XCTAssertEqual(size.width, maxWidth, accuracy: 0.5, "块宽应为两行最大宽")
        XCTAssertEqual(size.height, ToolbarLayout.rowHeight * 2 + ToolbarLayout.interRowGap, accuracy: 0.5)
    }

    func testSlotsAndRowFramesCoherent() {
        let ctx = context(tool: .rect)
        let slots = ToolbarLayout.slots(origin: .zero, context: ctx)
        // 每个 slot 的 control 非空时应有对应宽度，separator 宽度固定
        XCTAssertFalse(slots.isEmpty)
        for slot in slots where slot.control == nil {
            XCTAssertEqual(slot.frame.width, ToolbarStyle.separatorWidth)
            XCTAssertEqual(slot.frame.height, ToolbarLayout.rowHeight)
        }
        // 绘制与命中同源：union 高应等于 block 高
        if let union = ToolbarLayout.rowFrame(of: slots) {
            let size = ToolbarLayout.blockSize(ctx)
            XCTAssertEqual(union.height, size.height, accuracy: 0.5)
        }
    }

    func testThinToolStillTwoRowsIfHasColor() {
        // 文字工具只有 color+fontSize，也应双行（样式行非空）
        let ctx = context(tool: .text)
        let size = ToolbarLayout.blockSize(ctx)
        XCTAssertEqual(size.height, ToolbarLayout.rowHeight * 2 + ToolbarLayout.interRowGap)
    }

    func testHistoryControlsReserveStableDisabledSlots() {
        let ctx = context(tool: .rect)
        let controls = ToolbarLayout.slots(origin: .zero, context: ctx)
            .compactMap(\.control)
        let undo = controls.first { $0.id == "undo" }
        let redo = controls.first { $0.id == "redo" }

        XCTAssertNotNil(undo, "无历史时撤销仍应固定占位")
        XCTAssertNotNil(redo, "无历史时重做仍应固定占位")
        XCTAssertEqual(undo?.isEnabled(ctx), false)
        XCTAssertEqual(redo?.isEnabled(ctx), false)
    }

    func testPreciseScrollAccumulatesBeforeStepping() {
        var accumulator = ToolbarScrollAccumulator()

        XCTAssertNil(accumulator.step(delta: 2, isPrecise: true))
        XCTAssertNil(accumulator.step(delta: 3, isPrecise: true))
        XCTAssertEqual(accumulator.step(delta: 1, isPrecise: true), 1)
        XCTAssertEqual(accumulator.value, 0, accuracy: 0.001)
    }

    func testPreciseScrollDirectionChangeCancelsResidual() {
        var accumulator = ToolbarScrollAccumulator()

        XCTAssertNil(accumulator.step(delta: 4, isPrecise: true))
        XCTAssertNil(accumulator.step(delta: -3, isPrecise: true))
        XCTAssertNil(accumulator.step(delta: -2, isPrecise: true))
        XCTAssertEqual(accumulator.step(delta: -5, isPrecise: true), -1)
    }

    func testDiscreteWheelStepsImmediately() {
        var accumulator = ToolbarScrollAccumulator()

        XCTAssertEqual(accumulator.step(delta: 1, isPrecise: false), 1)
        XCTAssertEqual(accumulator.step(delta: -1, isPrecise: false), -1)
    }

    func testRecordAndScrollCaptureStayVisibleOnToolbar() {
        let ctx = context(tool: .rect)
        let controls = ToolbarLayout.slots(origin: .zero, context: ctx).compactMap(\.control)
        XCTAssertTrue(controls.contains { $0.id == "action.\(ActionID.record)" })
        XCTAssertTrue(controls.contains { $0.id == "action.\(ActionID.scrollCapture)" })

        let more = controls.compactMap { $0 as? MoreActionsControl }.first
        XCTAssertNotNil(more)
        XCTAssertFalse(more?.descriptors.contains { $0.id == ActionID.record } == true)
        XCTAssertFalse(more?.descriptors.contains { $0.id == ActionID.scrollCapture } == true)
    }

    func testNarrowToolbarKeepsRecordAndScrollCaptureIcons() {
        let ctx = context(tool: .rect)
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 600)
        let anchor = CGRect(x: 100, y: 250, width: 200, height: 180)
        let actions = ToolbarLayout.slots(in: bounds, anchor: anchor, context: ctx)
            .compactMap(\.control)
            .compactMap { $0 as? ActionControl }

        XCTAssertTrue(actions.contains { $0.descriptor.id == ActionID.record && !$0.showsTitle })
        XCTAssertTrue(actions.contains { $0.descriptor.id == ActionID.scrollCapture && !$0.showsTitle })
    }

    func testNarrowCaptureToolbarStaysInsideSupportedWidth() {
        let ctx = context(tool: .rect)
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 600)
        let anchor = CGRect(x: 100, y: 250, width: 200, height: 180)
        let slots = ToolbarLayout.slots(in: bounds, anchor: anchor, context: ctx)

        XCTAssertFalse(slots.isEmpty)
        XCTAssertGreaterThanOrEqual(slots.map(\.frame.minX).min() ?? 0, bounds.minX + 4)
        XCTAssertLessThanOrEqual(slots.map(\.frame.maxX).max() ?? 0, bounds.maxX - 4)
        XCTAssertTrue(
            slots.compactMap(\.control).compactMap { $0 as? ActionControl }.allSatisfy { !$0.showsTitle },
            "窄屏应保留动作图标并收起文字"
        )
    }

    func testToolbarFocusWrapsInBothDirections() {
        let ids = ["pointer", "rect", "copy"]
        XCTAssertEqual(ToolbarFocusNavigator.next(in: ids, current: nil, offset: 1), "pointer")
        XCTAssertEqual(ToolbarFocusNavigator.next(in: ids, current: nil, offset: -1), "copy")
        XCTAssertEqual(ToolbarFocusNavigator.next(in: ids, current: "copy", offset: 1), "pointer")
        XCTAssertEqual(ToolbarFocusNavigator.next(in: ids, current: "pointer", offset: -1), "copy")
    }

    func testExecutingActionIsBusyAndDisabled() {
        let ctx = context(tool: .rect, executingActions: [ActionID.copy])
        let copy = ToolbarLayout.slots(origin: .zero, context: ctx)
            .compactMap(\.control)
            .first { $0.id == "action.\(ActionID.copy)" }

        XCTAssertNotNil(copy)
        XCTAssertEqual(copy?.isBusy(ctx), true)
        XCTAssertEqual(copy?.isEnabled(ctx), false)
        XCTAssertEqual(copy?.accessibilityLabel(ctx), "正在复制")
    }

    func testActionExecutionTrackerRejectsDuplicateUntilFinished() {
        var tracker = ActionExecutionTracker()
        XCTAssertTrue(tracker.begin(ActionID.upload))
        XCTAssertTrue(tracker.isExecuting(ActionID.upload))
        XCTAssertFalse(tracker.begin(ActionID.upload))

        tracker.finish(ActionID.upload)
        XCTAssertFalse(tracker.isExecuting(ActionID.upload))
        XCTAssertTrue(tracker.begin(ActionID.upload))
    }

    func testMoreActionsShowsBusyWithoutBlockingOtherActions() {
        let ctx = context(tool: .rect, executingActions: [ActionID.upload])
        let more = ToolbarLayout.slots(origin: .zero, context: ctx)
            .compactMap(\.control)
            .compactMap { $0 as? MoreActionsControl }
            .first

        XCTAssertNotNil(more)
        XCTAssertEqual(more?.isBusy(ctx), true)
        XCTAssertEqual(more?.isEnabled(ctx), true)
        XCTAssertEqual(more?.accessibilityLabel(ctx), "更多操作（有操作正在执行）")
    }
}
