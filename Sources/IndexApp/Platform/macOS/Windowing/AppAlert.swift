import AppKit

/// 应用内弹窗的统一入口。`NSAlert` 的构造与呈现只在这里发生 ——
/// 与 `SystemNavigator` / `ImageExporter` 同一套纪律，界面层不再散落
/// 八种自己拼的 runModal / beginSheetModal。
///
/// 三种形态：
/// - `confirm`：要用户做选择，**同步**返回按了第几个按钮（应用模态 ——
///   调用方多是 `guard` 式的同步分支，sheet 的异步回调表达不了）。
/// - `info` / `error`：单向告知，不需要返回值。有宿主窗口时挂 sheet，
///   没有（或宿主已关）时退回应用模态兜底。
@MainActor
enum AppAlert {

    /// 确认框：按 `buttons` 顺序加按钮（第一个是 ⏎ 默认按钮），
    /// 返回被点按钮的序号（0 起）。
    static func confirm(
        _ title: String,
        message: String,
        style: NSAlert.Style = .warning,
        buttons: [String]
    ) -> Int {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = style
        for button in buttons {
            alert.addButton(withTitle: button)
        }
        // App 不在前台时（菜单栏触发的流程）模态框会沉底，先拉到前面。已激活时是空操作。
        NSApp.activate(ignoringOtherApps: true)
        // 和存盘面板同病：没有宿主窗口的模态框会被台前调度算进 Index 那一组，
        // 弹出来时把用户正在用的 App 挤进侧边条，自己还跑去图库那块屏上。
        PanelPlacement.apply(to: alert.window, anchor: nil)
        let response = alert.runModal()
        return response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
    }

    /// 提示（只有默认「好」按钮）。
    static func info(_ title: String, message: String, host: NSWindow? = nil) {
        present(title: title, message: message, style: .informational, host: host)
    }

    /// 错误提示。
    static func error(_ title: String, message: String, host: NSWindow? = nil) {
        present(title: title, message: message, style: .warning, host: host)
    }

    /// 错误提示（正文取错误的本地化描述）。
    static func error(_ title: String, error: Error, host: NSWindow? = nil) {
        present(
            title: title,
            message: error.localizedDescription,
            style: .warning,
            host: host
        )
    }

    /// 单向告知的共用呈现：sheet 优先，无宿主窗口时模态兜底。
    private static func present(
        title: String, message: String, style: NSAlert.Style, host: NSWindow?
    ) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = style
        if let host, host.isVisible {
            alert.beginSheetModal(for: host)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            PanelPlacement.apply(to: alert.window, anchor: nil)
            alert.runModal()
        }
    }
}
