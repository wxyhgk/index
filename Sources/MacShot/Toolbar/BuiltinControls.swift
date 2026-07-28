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
        guard context.annotation.tool == tool else { return false }
        guard tool == nil else { return true }
        switch context.scope {
        case .capture:
            // 截图有中性态：tool == nil 且未进入鼠标模式时谁都不高亮。
            return context.annotation.pointerEngaged
        case .pinned:
            // 选字模式激活时指针按钮不再高亮（两者都对应 annotation.tool == nil）。
            return !context.isLiveTextActive()
        }
    }

    func draw(in frame: CGRect, context: ToolbarContext, state: ToolbarRenderState) {
        ToolbarStyle.drawCenteredSymbol(tool?.symbolName ?? "cursorarrow", in: frame)
    }

    func activate(_ context: ToolbarContext) {
        context.annotation.endTextEditing()
        context.annotation.tool = tool
        // 点指针 = 主动进入鼠标模式；拿起画笔 = 离开。
        // 钉图/编辑器不读这个标记，行为不变（见 AnnotationState.pointerEngaged）。
        context.annotation.pointerEngaged = tool == nil
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
    var group: ToolbarGroup { .tools }
    /// 工具组尾部（画笔在 0 起的小序号，这里刻意拉开距离）。
    var order: Int { 1000 }

    /// "text.viewfinder" 已被「取字」动作占用，这里用 I-beam 光标的符号。
    func isVisible(_ context: ToolbarContext) -> Bool { context.toggleLiveText != nil }
    func isSelected(_ context: ToolbarContext) -> Bool { context.isLiveTextActive() }

    func draw(in frame: CGRect, context: ToolbarContext, state: ToolbarRenderState) {
        ToolbarStyle.drawCenteredSymbol("character.cursor.ibeam", in: frame)
    }

    func activate(_ context: ToolbarContext) {
        context.toggleLiveText?()
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

// MARK: - 效果开关（美化 / 带壳 / 水印 / 捕获信息）

/// 效果层的开关控件。效果不是画笔而是**输出选项** —— 点一下经
/// `AnnotationState.toggleEffect` 加/删一层对应的效果层（单例语义、可撤销），
/// 参数与元数据由描述符（`EffectRegistry`）在开关那一刻烤入。
/// 四个效果只差 id / 次序 / 图标 / kind，这里参数化成一个控件、登记处注册四次；
/// 样式子选项（预设 / 模式 / 壳样式 / 字段勾选）在图库编辑器的效果面板里。
struct EffectToggleControl: ToolbarControl {
    let id: String
    /// 排在颜色（0..）和粗细（100..）之后（300..）。
    let order: Int
    let symbolName: String
    let kind: Layer.Kind

    /// 只在钉图上出现：截图工具条为保持精简撤掉了输出开关 ——
    /// 截图阶段要效果的用户可以钉图后再开，或去图库编辑器调。
    /// 「导出自动加水印」在协调器里，不走这个开关，截图阶段照常生效。
    var scopes: Set<ActionScope> { [.pinned] }
    var group: ToolbarGroup { .style }

    /// 恒可见：指针模式下也能开关 —— 输出选项不依赖任何工具。
    func isVisible(_ context: ToolbarContext) -> Bool { true }

    func isSelected(_ context: ToolbarContext) -> Bool {
        context.annotation.hasEffect(kind)
    }

    func draw(in frame: CGRect, context: ToolbarContext, state: ToolbarRenderState) {
        ToolbarStyle.drawCenteredSymbol(symbolName, in: frame)
    }

    func activate(_ context: ToolbarContext) {
        context.annotation.toggleEffect(kind)
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

/// 「更多」：截图工具条上收纳非主力动作（取字 / 报告 / 上传）的菜单控件。
/// 点开一个 NSMenu 列出全部收纳项，选中即 perform —— 和平铺按钮走同一条出口。
/// 由 `ToolbarRegistry.controls(for:)` 按描述符聚合生成，不在登记处出现。
struct MoreActionsControl: ToolbarControl {
    let descriptors: [ToolbarActionDescriptor]
    let order: Int
    let scope: ActionScope

    var id: String { "action.more" }
    var scopes: Set<ActionScope> { [scope] }
    var group: ToolbarGroup { .actions }

    func draw(in frame: CGRect, context: ToolbarContext, state: ToolbarRenderState) {
        ToolbarStyle.drawCenteredSymbol("ellipsis.circle", in: frame)
    }

    func activate(_ context: ToolbarContext) {
        // 控件只知道自己被点了，不知道自己画在哪 ——
        // 按 AppKit 惯例在触发它的鼠标事件位置弹出（popUpContextMenu）。
        guard let event = NSApp.currentEvent, let window = event.window,
              let view = window.contentView else { return }

        let target = MoreActionsMenuTarget(perform: context.perform)
        // NSMenuItem.target 是弱引用；菜单存续期间由这里保活，下次弹出时替换。
        Self.retainedTarget = target

        let menu = NSMenu()
        for descriptor in descriptors {
            let item = NSMenuItem(
                title: descriptor.title,
                action: #selector(MoreActionsMenuTarget.run(_:)),
                keyEquivalent: ""
            )
            item.target = target
            item.representedObject = descriptor.id
            // 用原生符号图（不走 ToolbarStyle 的白色填充）—— 菜单要适配浅色外观。
            item.image = NSImage(
                systemSymbolName: descriptor.symbolName,
                accessibilityDescription: descriptor.title
            )
            menu.addItem(item)
        }

        // 截图覆盖窗在 .screenSaver 层，比菜单窗口（.popUpMenu = 101）还高 ——
        // 不降级菜单会弹在覆盖层背后。跟踪期间临时降到 .popUpMenu（仍高于普通窗口，
        // 冻结画面照旧盖住全屏），popUpContextMenu 同步阻塞到菜单收起，之后恢复。
        let savedLevel = window.level
        if savedLevel.rawValue > NSWindow.Level.popUpMenu.rawValue {
            window.level = .popUpMenu
        }
        NSMenu.popUpContextMenu(menu, with: event, for: view)
        window.level = savedLevel
    }

    @MainActor private static var retainedTarget: MoreActionsMenuTarget?
}

/// NSMenuItem 的 target/action 落点。菜单项没有闭包 API，这里做一层最小转接。
private final class MoreActionsMenuTarget: NSObject {
    private let perform: (String) -> Void

    init(perform: @escaping (String) -> Void) {
        self.perform = perform
        super.init()
    }

    @objc func run(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        perform(id)
    }
}

// MARK: - 登记

extension ToolbarRegistry {

    /// 常驻工具条的工具。椭圆、高亮、聚光灯、测量、序号只保留快捷键
    /// （O / H / S / M / N）—— 截图标注里「指出、框住、写字、打码」是绝对主力，
    /// 快捷键激活的非常驻工具会临时露面（见 `ToolControl.isVisible`）。
    static let pinnedTools: [AnnotationTool] = [.rect, .arrow, .text, .pixelate]

    static func registerBuiltins(into registry: ToolbarRegistry) {
        registry.register(ToolControl(tool: nil, order: 0, isPinnedToBar: true))

        for (index, tool) in AnnotationTool.allCases.enumerated() {
            registry.register(ToolControl(
                tool: tool,
                order: index + 1,
                isPinnedToBar: pinnedTools.contains(tool)
            ))
        }

        registry.register(LiveTextControl())
        AnnotationState.palette.indices.forEach { registry.register(ColorControl(index: $0)) }
        AnnotationState.widths.indices.forEach { registry.register(WidthControl(index: $0)) }
        registry.register(EffectToggleControl(
            id: "backdrop", order: 300, symbolName: "sparkles", kind: .backdrop
        ))
        registry.register(EffectToggleControl(
            id: "frame", order: 310, symbolName: "macwindow", kind: .frame
        ))
        registry.register(EffectToggleControl(
            id: "watermark", order: 320, symbolName: "signature", kind: .watermark
        ))
        registry.register(EffectToggleControl(
            id: "captureInfo", order: 330, symbolName: "info.square", kind: .captureInfo
        ))
        registry.register(UndoControl())
        registry.register(RedoControl())
    }
}
