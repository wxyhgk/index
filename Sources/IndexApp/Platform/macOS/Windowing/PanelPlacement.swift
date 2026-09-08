import AppKit

/// 没有宿主窗口的模态面板（存盘、选目录）该出现在哪块屏、归谁管。
///
/// 要解决的是两个叠在一起的毛病，多屏 + 台前调度下尤其明显：
///
/// **一、跑错屏。** Index 是 accessory App，选区覆盖层在动作执行**之前**就收掉了，
/// 面板打开的那一刻常常一个 key 窗口都没有。AppKit 这时按 `NSScreen.main` 摆放，
/// 而多屏下 `NSScreen.main` 跟的是菜单栏/指针那块屏 —— 不是刚才截图的那块。
/// 实测（三屏）：在主屏截图、指针在副屏时，存盘面板弹到了副屏上。
///
/// **二、把用户正在用的 App 挤进侧边条。** 默认行为下面板算 Index 的「主窗口」，
/// 和图库窗口属于同一组 stage。于是在别的屏截图点保存时，台前调度会把 Index
/// 整组 stage 拽到前台：用户当前的 App 被缩进左侧窗口条，而面板跟着图库跑到了
/// 图库那块屏上 —— 人在这块屏，只能靠快捷键把图库调出来才看得见它。
/// 这正是 `detachFromAppStage` 存在的理由。
///
/// 还有一条实测结论决定了这里的用法：`runModal()` **之前** `setFrameOrigin` 无效 ——
/// 面板上屏时会自己恢复上次记住的位置，把我们摆的覆盖掉。所以只能在模态 runloop
/// 起来之后再摆一次（主队列的 block 在模态 runloop 里照常执行，已验证）。
@MainActor
enum PanelPlacement {

    /// 解析目标屏。优先级：明确的锚点矩形 → key 窗口 → 指针 → 主屏。
    ///
    /// - Parameter anchor: 触发者在 AppKit 全局坐标里的矩形（截图选区）。
    ///   钉图窗口、图库、编辑器都传不出这个信息，靠后面几级兜底 ——
    ///   用户刚点过按钮，指针就在正确的那块屏上。
    static func targetScreen(anchor: CGRect?) -> NSScreen? {
        if let anchor, !anchor.isEmpty {
            let center = CGPoint(x: anchor.midX, y: anchor.midY)
            if let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }) {
                return screen
            }
        }
        if let keyScreen = NSApp.keyWindow?.screen { return keyScreen }
        return NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main
    }

    /// 面板在目标屏上的落点：水平居中、垂直偏上（空隙的三分之一留在上面，
    /// 与 `NSWindow.center()` 的观感一致），越界收回可见区域。
    ///
    /// 纯函数、可测 —— 竖屏（720pt 宽）比面板还窄，居中会挂出去半截。
    nonisolated static func origin(panelSize: CGSize, in visible: CGRect) -> CGPoint {
        var origin = CGPoint(
            x: visible.midX - panelSize.width / 2,
            y: visible.maxY - panelSize.height - max(0, visible.height - panelSize.height) / 3
        )
        // 屏比面板小时 max(...) 保证下界不会超过上界，最终贴左/贴下而不是乱飞。
        origin.x = min(max(origin.x, visible.minX), max(visible.minX, visible.maxX - panelSize.width))
        origin.y = min(max(origin.y, visible.minY), max(visible.minY, visible.maxY - panelSize.height))
        return origin
    }

    /// 让面板脱离「Index 这一组窗口」，改成跟着用户当前所在的 stage / space 走。
    ///
    /// macOS 13 为台前调度加的两个行为正是干这个的：
    ///   - `.auxiliary`：我不是主窗口，别拿我单开一个 stage、也别为我把整组窗口拽出来；
    ///   - `.canJoinAllApplications`：我可以显示在**别的 App** 的 stage 旁边。
    /// 再加 `.moveToActiveSpace`，多桌面下也跟着用户走。
    ///
    /// 三对标志位在 AppKit 里是互斥的，所以先摘掉对立面再设，避免行为未定义。
    static func detachFromAppStage(_ panel: NSWindow) {
        var behavior = panel.collectionBehavior
        behavior.remove(.primary)
        behavior.insert(.auxiliary)
        behavior.insert(.canJoinAllApplications)
        // `.canJoinAllSpaces` 与 `.moveToActiveSpace` 互斥；前者已经是「哪都在」，不必再动。
        if !behavior.contains(.canJoinAllSpaces) {
            behavior.insert(.moveToActiveSpace)
        }
        panel.collectionBehavior = behavior
    }

    /// 给「一个窗口都没有」的场合（截图动作）造一个挂 sheet 用的宿主：
    /// 透明、无边框、点击穿透、浮在普通窗口之上，铺在目标屏的可见区域上。
    /// 用户看不见它，它只是个锚点。
    ///
    /// 关键是 `.nonactivatingPanel` —— 挂在它上面的 sheet 能拿到键盘焦点，
    /// 却不需要 `NSApp.activate(ignoringOtherApps:)` 把 App 的所有窗口都拉到前台
    /// （那正是台前调度把图库那组 stage 拽出来的原因）。这套组合是实测出来的，
    /// 同样条件下 `runModal` 无论配不配宿主都拿不到 key。
    static func makeSheetHost(anchor: CGRect?) -> NSPanel {
        let screen = targetScreen(anchor: anchor) ?? NSScreen.screens[0]
        let host = SheetHostPanel(
            contentRect: screen.visibleFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        host.isOpaque = false
        host.backgroundColor = .clear
        host.hasShadow = false
        host.level = .modalPanel
        // 宿主自己不该拦任何点击 —— sheet 是独立窗口，照常收事件。
        host.ignoresMouseEvents = true
        host.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        host.orderFrontRegardless()
        host.makeKey()
        return host
    }

    /// 无边框窗口默认不能成为 key，而 sheet 要靠宿主这条链拿焦点。
    private final class SheetHostPanel: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    /// 在 `runModal()` **之前**调用，一次把两件事办掉：脱离 App 的 stage、
    /// 并登记一个主队列 block，等面板上屏后把它摆到目标屏。
    /// 摆放必须等上屏之后 —— 那时面板才恢复完自己的尺寸，算出来的居中才是准的。
    static func apply(to panel: NSWindow, anchor: CGRect?) {
        detachFromAppStage(panel)
        guard let screen = targetScreen(anchor: anchor) else { return }
        let visible = screen.visibleFrame
        DispatchQueue.main.async { [weak panel] in
            guard let panel else { return }
            panel.setFrameOrigin(origin(panelSize: panel.frame.size, in: visible))
        }
    }
}
