import AppKit

// ============================================================
// MARK: - 内置工具条控件：工具选择 + 历史操作
//
// AnnotationEntryControl / ToolControl / LiveTextControl /
// ShapeVariantControl / UndoControl / RedoControl。
// ============================================================

// MARK: - 标注分组入口

/// 第一栏的「标注」按钮。点击弹出下拉菜单选择标注工具，
/// 选中后第二栏展开样式（颜色/线宽/撤销/重做）。
struct AnnotationEntryControl: ToolbarControl {
    let id = "annotation.entry"
    var scopes: Set<ActionScope> { [.capture, .pinned] }
    var group: ToolbarGroup { .entry }
    var order: Int { 0 }

    func isSelected(_ context: ToolbarContext) -> Bool {
        guard let tool = context.annotation.tool else { return false }
        return tool != .magnifier
    }

    func accessibilityLabel(_ context: ToolbarContext) -> String {
        if let tool = context.annotation.tool, tool != .magnifier {
            return "标注（\(tool.title)）"
        }
        return "标注"
    }

    func width(_ context: ToolbarContext) -> CGFloat {
        ToolbarStyle.horizontalPadding * 2
            + ToolbarStyle.iconSize
            + ToolbarStyle.iconGap
            + ToolbarStyle.labelWidth("标注")
    }

    func draw(in frame: CGRect, context: ToolbarContext, state: ToolbarRenderState) {
        let symbol: String
        if let tool = context.annotation.tool, tool != .magnifier {
            symbol = tool.symbolName
        } else {
            symbol = "square.and.pencil"
        }
        ToolbarStyle.drawIconAndLabel(symbol, "标注", in: frame)
    }

    func activate(_ context: ToolbarContext) {
        context.annotation.endTextEditing()
        context.capabilities.deactivateAll()
        if isSelected(context) {
            context.annotation.tool = nil
            context.annotation.pointerEngaged = true
        } else {
            context.annotation.tool = .rect
            context.annotation.pointerEngaged = false
        }
    }

    @MainActor private static var retainedTarget: AnnotationMenuTarget?
}

private final class AnnotationMenuTarget: NSObject {
    private let onSelect: (AnnotationTool) -> Void

    init(onSelect: @escaping (AnnotationTool) -> Void) {
        self.onSelect = onSelect
        super.init()
    }

    @objc func select(_ sender: NSMenuItem) {
        guard let tool = sender.representedObject as? AnnotationTool else { return }
        onSelect(tool)
    }
}

// MARK: - 标注工具

struct ToolControl: ToolbarControl {
    /// nil 表示指针模式。
    let tool: AnnotationTool?
    let order: Int
    /// 常驻工具条，还是只在被快捷键激活时临时露面。
    let isPinnedToBar: Bool

    var id: String { "tool.\(tool?.layerKind.rawValue ?? "pointer")" }
    var scopes: Set<ActionScope> { [.capture, .pinned] }
    var group: ToolbarGroup {
        tool == .magnifier ? .entry : .annotation
    }

    /// 放大（magnifier）始终在第一栏；
    /// 常用标注工具在标注模式时平铺第二栏；
    /// 非常用工具通过「标注」菜单或快捷键激活。
    func isVisible(_ context: ToolbarContext) -> Bool {
        guard let tool else { return false }
        if tool == .magnifier { return true }
        guard AnnotationTool.commonTools.contains(tool) else { return false }
        guard let current = context.annotation.tool else { return false }
        return current != .magnifier
    }

    func isSelected(_ context: ToolbarContext) -> Bool {
        guard context.annotation.tool == tool else { return false }
        guard tool == nil else { return true }
        switch context.scope {
        case .capture:
            // 截图有中性态：tool == nil 且未进入鼠标模式时谁都不高亮。
            return context.annotation.pointerEngaged && !context.capabilities.hasActiveMode
        case .pinned:
            // 临时画布模式激活时指针按钮不再高亮。
            return !context.capabilities.hasActiveMode
        }
    }

    func accessibilityLabel(_ context: ToolbarContext) -> String {
        if let tool {
            let shortcut = ToolRegistry.descriptor(for: tool).shortcut?.label
            return shortcut.map { "\(tool.title)（\($0)）" } ?? tool.title
        }
        return "指针（V）"
    }

    func draw(in frame: CGRect, context: ToolbarContext, state: ToolbarRenderState) {
        ToolbarStyle.drawCenteredSymbol(tool?.symbolName ?? "cursorarrow", in: frame)
    }

    func activate(_ context: ToolbarContext) {
        context.annotation.endTextEditing()
        context.capabilities.deactivateAll()
        // 点击已选中的工具 = 取消（toggle 回指针），给用户直观的退出路径。
        if context.annotation.tool == tool {
            context.annotation.tool = nil
            context.annotation.pointerEngaged = true
        } else {
            context.annotation.tool = tool
            context.annotation.pointerEngaged = tool == nil
        }
    }
}

// MARK: - 选字（系统实况文本）

/// 「选字」开关。激活后在画面上叠一层系统 `ImageAnalysisOverlayView` ——
/// 拖选文字、词级命中、右键复制全部原生（就是系统「实况文本」）。
/// 它不是画笔：激活时画标注 / 调整选区的手势暂停；
/// 再点一次、Esc 或切到别的工具退出。设备不支持时宿主不传 toggle，控件不出现。
///
/// 只在钉图上出现：截图工具条没有独立「选字」——
/// 选字并进了鼠标（指针）模式（见 `OverlayView` 的 pointerEngaged）。
struct LiveTextControl: ToolbarControl {
    static let controlID = "liveText"

    var id: String { Self.controlID }
    var scopes: Set<ActionScope> { [.pinned] }
    var group: ToolbarGroup { .annotation }
    /// 工具组尾部（画笔在 0 起的小序号，这里刻意拉开距离）。
    var order: Int { 1000 }

    /// 已收敛到鼠标模式：钉图现在与截图一致，选字并进「鼠标」不再需要独立按钮。
    /// 保留类型仅作兼容，永不显示（见 PinImageView.viewDidMoveToWindow 自动进入）。
    func isVisible(_ context: ToolbarContext) -> Bool { false }
    func isSelected(_ context: ToolbarContext) -> Bool {
        context.capabilities.isActive(.liveText)
    }
    func accessibilityLabel(_ context: ToolbarContext) -> String { "选字" }

    func draw(in frame: CGRect, context: ToolbarContext, state: ToolbarRenderState) {
        ToolbarStyle.drawCenteredSymbol("character.cursor.ibeam", in: frame)
    }

    func activate(_ context: ToolbarContext) {
        context.capabilities.toggleExclusive(.liveText)
    }
}

// MARK: - 形状变体（PixPin 第二行左侧：矩形↔圆形）
//
// 矩形与椭圆共用同一把画笔的“样式”—— PixPin 在选中矩形后，下行左侧露出
// 两个可切的形状（□/○），而非顶行再占一个椭圆按钮。此处用两个
// 样式行控件复刻：任一“框选类”工具（rect/ellipse）激活时同时露面，
// 点选即切工具，其余样式（颜色/粗细）随切后的工具自动刷新。
// 只在截图与钉图两种场景露面，排序置于样式行最前（order < 0）。
struct ShapeVariantControl: ToolbarControl {
    let tool: AnnotationTool

    var id: String { "shape.\(tool.layerKind.rawValue)" }
    var scopes: Set<ActionScope> { [.capture, .pinned] }
    var group: ToolbarGroup { .style }
    // 方在前、圆在后；都小于颜色/粗细的 0/100，确保在样式行最左侧。
    var order: Int { tool == .rect ? -20 : -19 }

    func isVisible(_ context: ToolbarContext) -> Bool {
        guard let cur = context.annotation.styleTool else { return false }
        return cur == .rect || cur == .ellipse
    }

    func isSelected(_ context: ToolbarContext) -> Bool {
        context.annotation.tool == tool
    }

    func accessibilityLabel(_ context: ToolbarContext) -> String { tool.title }

    func draw(in frame: CGRect, context: ToolbarContext, state: ToolbarRenderState) {
        // 与顶行工具共用同套符号，保证视觉一致；PixPin 第二行左侧即此意。
        ToolbarStyle.drawCenteredSymbol(tool.symbolName, in: frame, pointSize: 14)
    }

    func activate(_ context: ToolbarContext) {
        context.annotation.endTextEditing()
        context.capabilities.deactivateAll()
        context.annotation.tool = tool
        context.annotation.pointerEngaged = false
    }
}

// MARK: - 撤销 / 重做

struct UndoControl: ToolbarControl {
    let id = "undo"
    var scopes: Set<ActionScope> { [.capture, .pinned] }
    var group: ToolbarGroup { .history }
    var order: Int { 0 }

    /// 第二栏（标注模式）才显示；无标注工具时第二栏整体收起。
    func isVisible(_ context: ToolbarContext) -> Bool {
        guard let tool = context.annotation.tool else { return false }
        return tool != .magnifier
    }
    func isEnabled(_ context: ToolbarContext) -> Bool { context.annotation.canUndo }
    func accessibilityLabel(_ context: ToolbarContext) -> String { "撤销（Command-Z）" }

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

    /// 第二栏（标注模式）才显示；无标注工具时第二栏整体收起。
    func isVisible(_ context: ToolbarContext) -> Bool {
        guard let tool = context.annotation.tool else { return false }
        return tool != .magnifier
    }
    func isEnabled(_ context: ToolbarContext) -> Bool { context.annotation.canRedo }
    func accessibilityLabel(_ context: ToolbarContext) -> String { "重做（Shift-Command-Z）" }

    func draw(in frame: CGRect, context: ToolbarContext, state: ToolbarRenderState) {
        ToolbarStyle.drawCenteredSymbol("arrow.uturn.forward", in: frame, pointSize: 13)
    }

    func activate(_ context: ToolbarContext) {
        context.annotation.redo()
    }
}

