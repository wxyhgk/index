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

// MARK: - 颜色与粗细

struct ColorControl: ToolbarControl {
    let index: Int

    var id: String { "color.\(index)" }
    var scopes: Set<ActionScope> { [.capture, .pinned] }
    var group: ToolbarGroup { .style }
    var order: Int { index }

    /// 只有**声明了颜色轴**的工具才显示色块。马赛克 / 聚光灯 / 裁剪的渲染
    /// 根本不读 `layer.color` —— 从前它们照样摆一排点了没反应的色块。
    func isVisible(_ context: ToolbarContext) -> Bool {
        context.annotation.styleAxes.contains(.color)
    }
    func isSelected(_ context: ToolbarContext) -> Bool {
        context.annotation.styleIndex(for: .color) == index
    }
    func accessibilityLabel(_ context: ToolbarContext) -> String { "颜色 \(index + 1)" }
    func width(_ context: ToolbarContext) -> CGFloat { ToolbarStyle.swatchWidth }

    func draw(in frame: CGRect, context: ToolbarContext, state: ToolbarRenderState) {
        let color = AnnotationState.palette[index]
        NSColor(srgbRed: color.r, green: color.g, blue: color.b, alpha: 1).setFill()
        let dot = NSRect(x: frame.midX - DS.toolDotSize / 2, y: frame.midY - DS.toolDotSize / 2, width: DS.toolDotSize, height: DS.toolDotSize)
        NSBezierPath(ovalIn: dot).fill()

        NSColor.black.withAlphaComponent(0.35).setStroke()
        let ring = NSBezierPath(ovalIn: dot)
        ring.lineWidth = DS.hairline
        ring.stroke()
    }

    func activate(_ context: ToolbarContext) {
        context.annotation.setStyleIndex(index, for: .color)
        // 有选中图层时顺带改它的颜色 —— 「点中再点色」是最直觉的改色方式。
        context.annotation.applyColorToSelection()
    }
}

/// 数值型样式轴的档位控件（粗细 / 字号 / 透明度 / 颗粒 / 压暗）。
///
/// 一根轴三档，登记处按 `ToolStyleAxis` × 档位注册一遍；**只有当前工具声明了
/// 这根轴时才出现**。从前只有「粗细」一个控件，而字号是从粗细派生的
/// （`线宽 × 4 + 8`）——调矩形边框粗细会顺手改掉文字大小。
struct ToolParamControl: ToolbarControl {
    let axis: ToolStyleAxis
    let index: Int

    var id: String { "param.\(axis.rawValue).\(index)" }
    var scopes: Set<ActionScope> { [.capture, .pinned] }
    var group: ToolbarGroup { .style }
    var order: Int { axis.order + index }

    func isVisible(_ context: ToolbarContext) -> Bool {
        context.annotation.styleAxes.contains(axis)
    }
    func isSelected(_ context: ToolbarContext) -> Bool {
        context.annotation.styleIndex(for: axis) == index
    }
    func accessibilityLabel(_ context: ToolbarContext) -> String {
        "\(axis.descriptor.title) \(index + 1)"
    }
    func width(_ context: ToolbarContext) -> CGFloat { 24 }

    /// 每根轴用自己的视觉语言表达「三档」，光看图标就知道在调什么：
    /// 粗细 = 圆点由小到大；字号 = 字母 A 由小到大；透明度 = 同色不同浓淡；
    /// 颗粒 = 方格由密到疏；压暗 = 灰度由浅到深。
    /// 绘制由 `ToolStyleAxisDescriptor` 统一声明，新增轴无需再改这里。
    func draw(in frame: CGRect, context: ToolbarContext, state: ToolbarRenderState) {
        axis.descriptor.toolbarDraw?(frame, index)
    }

    func activate(_ context: ToolbarContext) {
        context.annotation.setStyleIndex(index, for: axis)
        context.annotation.applyStyleToSelection(axis)
    }
}

// MARK: - 效果开关（美化 / 带壳 / 水印 / 捕获信息）

/// 效果层的开关控件。效果不是画笔而是**输出选项** —— 点一下经
/// `AnnotationState.toggleEffect` 加/删一层对应的效果层（单例语义、可撤销），
/// 参数与元数据由描述符（`EffectRegistry`）在开关那一刻烤入。
/// 控件本身是参数化的，登记处按 `EffectRegistry.displayOrdered` 循环注册；
/// 样式子选项（预设 / 模式 / 壳样式 / 字段勾选）在图库编辑器的效果面板里。
struct EffectToggleControl: ToolbarControl {
    let id: String
    /// 排在颜色（0..）和粗细（100..）之后（300..）。
    let order: Int
    let symbolName: String
    let kind: Layer.Kind
    let title: String

    /// 从注册表描述符构造。新增效果只需在 `EffectRegistry` 声明一处，
    /// 工具条与编辑器面板自动跟随，无需在此追加硬编码注册行。
    init(descriptor: EffectDescriptor) {
        self.id = descriptor.id
        self.order = descriptor.toolbarOrder
        self.symbolName = descriptor.symbolName
        self.kind = descriptor.kind
        self.title = descriptor.panelTitle
    }

    init(id: String, order: Int, symbolName: String, kind: Layer.Kind) {
        self.id = id
        self.order = order
        self.symbolName = symbolName
        self.kind = kind
        self.title = id
    }

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
    func accessibilityLabel(_ context: ToolbarContext) -> String { title }

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

    /// 固定占位，避免历史栈变化时把右侧复制/保存按钮横向推走。
    func isVisible(_ context: ToolbarContext) -> Bool { true }
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

    func isVisible(_ context: ToolbarContext) -> Bool { true }
    func isEnabled(_ context: ToolbarContext) -> Bool { context.annotation.canRedo }
    func accessibilityLabel(_ context: ToolbarContext) -> String { "重做（Shift-Command-Z）" }

    func draw(in frame: CGRect, context: ToolbarContext, state: ToolbarRenderState) {
        ToolbarStyle.drawCenteredSymbol("arrow.uturn.forward", in: frame, pointSize: 13)
    }

    func activate(_ context: ToolbarContext) {
        context.annotation.redo()
    }
}

// MARK: - 分子来源

/// XYZ 定格图片的来源入口。图标属于 Index 界面，不烤进 PNG；普通截图没有
/// `moleculeSourceActions`，因此不会占工具栏位置。
struct MoleculeSourceControl: ToolbarControl {
    let id = "molecule.source"
    var scopes: Set<ActionScope> { [.pinned] }
    var group: ToolbarGroup { .actions }
    var order: Int { -100 }

    func isVisible(_ context: ToolbarContext) -> Bool {
        context.moleculeSourceActions != nil
    }

    func accessibilityLabel(_ context: ToolbarContext) -> String { "分子来源" }

    func draw(in frame: CGRect, context: ToolbarContext, state: ToolbarRenderState) {
        ToolbarStyle.drawCenteredSymbol("atom", in: frame)
    }

    func activate(_ context: ToolbarContext) {
        guard let actions = context.moleculeSourceActions,
              let event = NSApp.currentEvent,
              let window = event.window,
              let view = window.contentView
        else { return }

        let target = MoleculeSourceMenuTarget(actions: actions)
        Self.retainedTarget = target
        let menu = NSMenu()
        menu.addItem(Self.item(
            title: "复制 XYZ 坐标",
            symbol: "doc.on.doc",
            command: .copy,
            target: target
        ))
        menu.addItem(Self.item(
            title: "用默认应用打开工作副本",
            symbol: "arrow.up.forward.app",
            command: .open,
            target: target
        ))
        menu.addItem(Self.item(
            title: "重新进入交互式 3D",
            symbol: "rotate.3d",
            command: .reopen,
            target: target
        ))

        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }

    private static func item(
        title: String,
        symbol: String,
        command: MoleculeSourceMenuTarget.Command,
        target: MoleculeSourceMenuTarget
    ) -> NSMenuItem {
        let item = NSMenuItem(
            title: title,
            action: #selector(MoleculeSourceMenuTarget.run(_:)),
            keyEquivalent: ""
        )
        item.target = target
        item.representedObject = command.rawValue
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        return item
    }

    @MainActor private static var retainedTarget: MoleculeSourceMenuTarget?
}

private final class MoleculeSourceMenuTarget: NSObject {
    enum Command: String { case copy, open, reopen }

    private let actions: MoleculeSourceActions

    init(actions: MoleculeSourceActions) {
        self.actions = actions
        super.init()
    }

    @objc func run(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let command = Command(rawValue: raw)
        else { return }
        switch command {
        case .copy: actions.copyXYZ()
        case .open: actions.openInDefaultApp()
        case .reopen: actions.reopen3D()
        }
    }
}

// MARK: - 出口动作（由 CaptureActionRegistry 自动展开，不需要单独登记）

struct ActionControl: ToolbarControl {
    let descriptor: ToolbarActionDescriptor
    let order: Int
    let scope: ActionScope
    let showsTitle: Bool

    init(
        descriptor: ToolbarActionDescriptor,
        order: Int,
        scope: ActionScope,
        showsTitle: Bool = true
    ) {
        self.descriptor = descriptor
        self.order = order
        self.scope = scope
        self.showsTitle = showsTitle
    }

    var id: String { "action.\(descriptor.id)" }
    var scopes: Set<ActionScope> { [scope] }
    var group: ToolbarGroup { .actions }
    func isEnabled(_ context: ToolbarContext) -> Bool {
        !context.isActionExecuting(descriptor.id)
    }
    func isBusy(_ context: ToolbarContext) -> Bool {
        context.isActionExecuting(descriptor.id)
    }
    func accessibilityLabel(_ context: ToolbarContext) -> String {
        isBusy(context) ? "正在\(descriptor.title)" : descriptor.title
    }

    func width(_ context: ToolbarContext) -> CGFloat {
        guard showsTitle else { return ToolbarStyle.iconButtonWidth }
        return ToolbarStyle.horizontalPadding * 2
            + ToolbarStyle.iconSize
            + ToolbarStyle.iconGap
            + ToolbarStyle.labelWidth(descriptor.title)
    }

    func draw(in frame: CGRect, context: ToolbarContext, state: ToolbarRenderState) {
        if state.isBusy {
            ToolbarStyle.drawCenteredSymbol("hourglass", in: frame)
            return
        }
        if showsTitle {
            ToolbarStyle.drawIconAndLabel(descriptor.symbolName, descriptor.title, in: frame)
        } else {
            ToolbarStyle.drawCenteredSymbol(descriptor.symbolName, in: frame)
        }
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
    func isBusy(_ context: ToolbarContext) -> Bool {
        descriptors.contains { context.isActionExecuting($0.id) }
    }
    func accessibilityLabel(_ context: ToolbarContext) -> String {
        isBusy(context) ? "更多操作（有操作正在执行）" : "更多操作"
    }

    func draw(in frame: CGRect, context: ToolbarContext, state: ToolbarRenderState) {
        ToolbarStyle.drawCenteredSymbol(
            state.isBusy ? "hourglass" : "ellipsis.circle",
            in: frame
        )
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
            item.isEnabled = !context.isActionExecuting(descriptor.id)
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
    ///
    /// 常驻与否现在是各工具描述符自己声明的（`isPinnedToBar`），
    /// 这里只是转发 —— 加一个工具不必回到这个文件改数组。
    static var pinnedTools: [AnnotationTool] { ToolRegistry.pinnedTools }

    static func registerBuiltins(into registry: ToolbarRegistry) {
        registry.register(ToolControl(tool: nil, order: 0, isPinnedToBar: true))

        // 顺序、常驻与否全部来自登记处（`BuiltinTools.all`）。
        for (index, descriptor) in ToolRegistry.descriptors.enumerated() {
            registry.register(ToolControl(
                tool: descriptor.tool,
                order: index + 1,
                isPinnedToBar: descriptor.isPinnedToBar
            ))
        }

        registry.register(LiveTextControl())
        registry.register(SelectionAIControl())
        // PixPin：选中矩形后下行左侧出矩形/圆形两格变体
        registry.register(ShapeVariantControl(tool: .rect))
        registry.register(ShapeVariantControl(tool: .ellipse))
        AnnotationState.palette.indices.forEach { registry.register(ColorControl(index: $0)) }
        // 数值轴 × 三档全部注册；哪些真正出现在条上由当前工具的描述符决定
        // （`ToolParamControl.isVisible` → `ToolRegistry.descriptor(for:).axes`）。
        // 档位数与轴清单均由 `ToolStyleAxisDescriptor` 统一声明。
        for descriptor in ToolStyleAxisDescriptor.all where descriptor.axis != .color {
            descriptor.steps.indices.forEach { registry.register(ToolParamControl(axis: descriptor.axis, index: $0)) }
        }
        // 效果开关统一由 `EffectRegistry` 驱动，新增效果只需在注册表声明一处。
        for descriptor in EffectRegistry.displayOrdered {
            registry.register(EffectToggleControl(descriptor: descriptor))
        }
        registry.register(UndoControl())
        registry.register(RedoControl())
        registry.register(MoleculeSourceControl())
    }
}
