import XCTest
@testable import MacShot

/// 工具条布局的纯函数安全网：无样式时单行，有样式时双行，命中与绘制同源。
@MainActor
final class ToolbarLayoutTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // 注册表在 App 启动时才装配，测试需手动拉起
        ToolbarRegistry.registerBuiltins(into: .shared)
        CaptureActionRegistry.registerBuiltins(into: .shared)
    }

    private func context(tool: AnnotationTool?) -> ToolbarContext {
        let state = AnnotationState()
        state.tool = tool
        // 中性态外，确保有工具时 styleAxes 非空才触发双行
        return ToolbarContext(annotation: state, scope: .capture, perform: { _ in })
    }

    func testSingleRowWhenNoStyle() {
        // 指针中性态：tool == nil 且 pointerEngaged == false → styleAxes == [] → 单行
        let state = AnnotationState()
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
}
