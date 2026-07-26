import AppKit

/// 内置控件。
///
/// 这个文件是「新增工具条控件」的唯一登记处。

// MARK: - 标注工具

struct ToolControl: ToolbarControl {
    /// nil 表示指针模式。
    let tool: AnnotationTool?
    let order: Int
    /// 常驻工具条，还是只在被快捷键激活时临时露面。
    let isPinnedToBar: Bool

    var id: String { "tool.\(tool?.layerKind.rawValue ?? "pointer")" }
    var scopes: Set<ActionScope> { [.capture, .pinned] }
    var group: ToolbarGroup { .tools }

    /// 用快捷键激活了非常驻工具时把它显示出来，
    /// 否则会出现「按了 H 但工具条上看不出选中了什么」。
    func isVisible(_ context: ToolbarContext) -> Bool {
        isPinnedToBar || context.annotation.tool == tool
    }

    func isSelected(_ context: ToolbarContext) -> Bool {
        context.annotation.tool == tool
    }

    func draw(in frame: CGRect, context: ToolbarContext, state: ToolbarRenderState) {
        ToolbarStyle.drawCenteredSymbol(tool?.symbolName ?? "cursorarrow", in: frame)
    }

    func activate(_ context: ToolbarContext) {
        context.annotation.endTextEditing()
        context.annotation.tool = tool
    }
}

// MARK: - 颜色与粗细

struct ColorControl: ToolbarControl {
    let index: Int

    var id: String { "color.\(index)" }
    var scopes: Set<ActionScope> { [.capture, .pinned] }
    var group: ToolbarGroup { .style }
    var order: Int { index }

    /// 拿着画笔、或选中了已画的图层时才有意义，其余时候不占位置。
    func isVisible(_ context: ToolbarContext) -> Bool {
        context.annotation.tool != nil || context.annotation.selectedID != nil
    }
    func isSelected(_ context: ToolbarContext) -> Bool { context.annotation.colorIndex == index }
    func width(_ context: ToolbarContext) -> CGFloat { ToolbarStyle.swatchWidth }

    func draw(in frame: CGRect, context: ToolbarContext, state: ToolbarRenderState) {
        let color = AnnotationState.palette[index]
        NSColor(srgbRed: color.r, green: color.g, blue: color.b, alpha: 1).setFill()
        let dot = NSRect(x: frame.midX - 6, y: frame.midY - 6, width: 12, height: 12)
        NSBezierPath(ovalIn: dot).fill()

        NSColor.black.withAlphaComponent(0.35).setStroke()
        let ring = NSBezierPath(ovalIn: dot)
        ring.lineWidth = 1
        ring.stroke()
    }

    func activate(_ context: ToolbarContext) {
        context.annotation.colorIndex = index
        // 有选中图层时顺带改它的颜色 —— 「点中再点色」是最直觉的改色方式。
        context.annotation.applyColorToSelection()
    }
}

struct WidthControl: ToolbarControl {
    let index: Int

    var id: String { "width.\(index)" }
    var scopes: Set<ActionScope> { [.capture, .pinned] }
    var group: ToolbarGroup { .style }
    /// 排在颜色后面。
    var order: Int { 100 + index }

    func isVisible(_ context: ToolbarContext) -> Bool {
        context.annotation.tool != nil || context.annotation.selectedID != nil
    }
    func isSelected(_ context: ToolbarContext) -> Bool { context.annotation.widthIndex == index }
    func width(_ context: ToolbarContext) -> CGFloat { 24 }

    func draw(in frame: CGRect, context: ToolbarContext, state: ToolbarRenderState) {
        let radius = CGFloat(AnnotationState.widths[index]) / 2 + 1.5
        NSColor.white.setFill()
        NSBezierPath(ovalIn: NSRect(
            x: frame.midX - radius,
            y: frame.midY - radius,
            width: radius * 2,
            height: radius * 2
        )).fill()
    }

    func activate(_ context: ToolbarContext) {
        context.annotation.widthIndex = index
        context.annotation.applyWidthToSelection()
    }
}

// MARK: - 美化（背景垫底 / 圆角 / 阴影）

/// 美化开关。它不是画笔而是**输出选项** —— 点一下加/删一层 backdrop，
/// 导出/复制的成品垫上渐变背景 + 圆角 + 投影；画布预览不变。
/// 覆盖层/钉图只做开关（默认预设），预设切换在图库编辑器里。
struct BackdropControl: ToolbarControl {
    let id = "backdrop"
    var scopes: Set<ActionScope> { [.capture, .pinned] }
    var group: ToolbarGroup { .style }
    /// 排在颜色（0..）和粗细（100..）之后。
    var order: Int { 300 }

    /// 恒可见：指针模式下也能开关 —— 它是输出选项，不依赖任何工具。
    func isVisible(_ context: ToolbarContext) -> Bool { true }

    func isSelected(_ context: ToolbarContext) -> Bool {
        context.annotation.hasBackdrop
    }

    func draw(in frame: CGRect, context: ToolbarContext, state: ToolbarRenderState) {
        ToolbarStyle.drawCenteredSymbol("sparkles", in: frame)
    }

    func activate(_ context: ToolbarContext) {
        context.annotation.toggleBackdrop()
    }
}

// MARK: - 撤销 / 重做

struct UndoControl: ToolbarControl {
    let id = "undo"
    var scopes: Set<ActionScope> { [.capture, .pinned] }
    var group: ToolbarGroup { .history }
    var order: Int { 0 }

    /// 没操作可撤的时候不占位置。看的是操作栈而不是图层数 ——
    /// 移动、删除、改样式都可撤，哪怕图层数没变。
    func isVisible(_ context: ToolbarContext) -> Bool { context.annotation.canUndo }

    func draw(in frame: CGRect, context: ToolbarContext, state: ToolbarRenderState) {
        ToolbarStyle.drawCenteredSymbol("arrow.uturn.backward", in: frame, pointSize: 13)
    }

    func activate(_ context: ToolbarContext) {
        context.annotation.undo()
    }
}

struct RedoControl: ToolbarControl {
    let id = "redo"
    var scopes: Set<ActionScope> { [.capture, .pinned] }
    var group: ToolbarGroup { .history }
    var order: Int { 1 }

    func isVisible(_ context: ToolbarContext) -> Bool { context.annotation.canRedo }

    func draw(in frame: CGRect, context: ToolbarContext, state: ToolbarRenderState) {
        ToolbarStyle.drawCenteredSymbol("arrow.uturn.forward", in: frame, pointSize: 13)
    }

    func activate(_ context: ToolbarContext) {
        context.annotation.redo()
    }
}

// MARK: - 出口动作（由 CaptureActionRegistry 自动展开，不需要单独登记）

struct ActionControl: ToolbarControl {
    let descriptor: ToolbarActionDescriptor
    let order: Int
    let scope: ActionScope

    var id: String { "action.\(descriptor.id)" }
    var scopes: Set<ActionScope> { [scope] }
    var group: ToolbarGroup { .actions }

    func width(_ context: ToolbarContext) -> CGFloat {
        ToolbarStyle.horizontalPadding * 2
            + ToolbarStyle.iconSize
            + ToolbarStyle.iconGap
            + ToolbarStyle.labelWidth(descriptor.title)
    }

    func draw(in frame: CGRect, context: ToolbarContext, state: ToolbarRenderState) {
        ToolbarStyle.drawIconAndLabel(descriptor.symbolName, descriptor.title, in: frame)
    }

    func activate(_ context: ToolbarContext) {
        context.perform(descriptor.id)
    }
}

// MARK: - 登记

extension ToolbarRegistry {

    /// 常驻工具条的工具。椭圆、高亮、聚光灯、测量只保留快捷键（O / H / S / M）——
    /// 截图标注里「指出、框住、写字、打码、标步骤」是绝对主力。
    static let pinnedTools: [AnnotationTool] = [.rect, .arrow, .text, .pixelate, .counter]

    static func registerBuiltins(into registry: ToolbarRegistry) {
        registry.register(ToolControl(tool: nil, order: 0, isPinnedToBar: true))

        for (index, tool) in AnnotationTool.allCases.enumerated() {
            registry.register(ToolControl(
                tool: tool,
                order: index + 1,
                isPinnedToBar: pinnedTools.contains(tool)
            ))
        }

        AnnotationState.palette.indices.forEach { registry.register(ColorControl(index: $0)) }
        AnnotationState.widths.indices.forEach { registry.register(WidthControl(index: $0)) }
        registry.register(BackdropControl())
        registry.register(UndoControl())
        registry.register(RedoControl())
    }
}
