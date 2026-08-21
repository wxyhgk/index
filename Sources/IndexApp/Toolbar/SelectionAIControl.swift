import AppKit

/// AI 选区是临时画布模式，不是 AnnotationTool：它不创建图层，也不进入标注撤销栈。
/// 是否出现完全由当前宿主是否提供 `.selectionAI` 能力决定。
struct SelectionAIControl: ToolbarControl {
    static let controlID = "selectionAI"

    var id: String { Self.controlID }
    var scopes: Set<ActionScope> { [.capture, .pinned] }
    var group: ToolbarGroup { .tools }
    var order: Int { 900 }

    func isVisible(_ context: ToolbarContext) -> Bool {
        context.capabilities.supports(.selectionAI)
    }

    func isSelected(_ context: ToolbarContext) -> Bool {
        context.capabilities.isActive(.selectionAI)
    }

    func accessibilityLabel(_ context: ToolbarContext) -> String {
        isSelected(context) ? "退出 AI 选区" : "AI 选区"
    }

    func draw(in frame: CGRect, context: ToolbarContext, state: ToolbarRenderState) {
        ToolbarStyle.drawCenteredSymbol("viewfinder", in: frame)
    }

    func activate(_ context: ToolbarContext) {
        context.annotation.endTextEditing()
        context.annotation.tool = nil
        context.annotation.pointerEngaged = false
        context.capabilities.toggleExclusive(.selectionAI)
    }
}
