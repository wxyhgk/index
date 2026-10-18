import AppKit

// ============================================================
// MARK: - 内置工具条控件：出口动作
//
// MoleculeSourceControl / ActionControl / MoreActionsControl
// 及其 private MenuTarget 类。
// ============================================================

// MARK: - 分子来源

/// XYZ 定格图片的来源入口。图标属于 Index 界面，不烤进 PNG；普通截图没有
/// `moleculeSourceActions`，因此不会占工具栏位置。
struct MoleculeSourceControl: ToolbarControl {
    let id = "molecule.source"
    var scopes: Set<ActionScope> { [.pinned] }
    var group: ToolbarGroup { .style }
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
        showsTitle: Bool = false
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

