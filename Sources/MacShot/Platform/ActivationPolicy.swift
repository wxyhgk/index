import AppKit

/// 不参与「是否还需要 Dock 图标」判断的窗口。
///
/// 选区覆盖层和钉图面板都属于这一类：它们可见不代表用户在「使用这个 App」，
/// 把它们算进去会让 App 永远停在 .regular，Dock 图标残留。
protocol TransientWindow: NSWindow {}

/// 菜单栏 App 的激活策略。
///
/// 平时 `.accessory`（不占 Dock），打开正经窗口时切 `.regular`（有窗口行为和菜单）。
/// 此前三个窗口控制器各写了一遍这段判断，其中图库那份**没有守卫** ——
/// 设置窗口开着时关掉图库，整个 App 会掉回 .accessory，菜单栏消失。
///
/// 阶段 3 会换成显式的引用计数；现在先把三份重复收成一份正确的。
@MainActor
enum ActivationPolicy {

    /// 打开一个正经窗口前调用。
    static func enterRegular() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 窗口关闭时调用。只有确实没有别的正经窗口了才退回菜单栏模式。
    /// - Parameter closing: 正在关闭的窗口。`windowWillClose` 触发时它还是 isVisible，
    ///   必须显式排除，否则永远判定为「还有窗口」。
    static func leaveRegularIfLastWindow(closing: NSWindow?) {
        let hasOther = NSApp.windows.contains { window in
            window.isVisible
                && window !== closing
                && !(window is TransientWindow)
        }
        if !hasOther {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
