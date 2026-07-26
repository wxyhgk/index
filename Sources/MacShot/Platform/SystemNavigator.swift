import AppKit

/// 跳转到系统的其它地方。收敛成一处，免得同一件事出现几种写法。
@MainActor
enum SystemNavigator {

    static func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// 用系统默认程序（网址就是默认浏览器）打开一个 URL。
    static func open(url: URL) {
        NSWorkspace.shared.open(url)
    }

    /// 激活指定 bundleID 的 App，没在运行就启动它。
    /// App 已被卸载时静默失败 —— 「回到出处」是尽力而为，不值得弹窗。
    static func activateApp(bundleID: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            NSLog("[MacShot] 找不到 App：\(bundleID)")
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }

    /// 弹目录选择面板，用户取消返回 nil。
    /// 模态面板收敛在平台层 —— 与 `ImageExporter.exportWithPanel` 同一套纪律，
    /// SwiftUI 视图里不裸跑 runModal。
    static func chooseDirectory(message: String = "选择文件夹") -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = message
        panel.prompt = "选择"

        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    static func openScreenRecordingSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    /// 当前前台 App。
    ///
    /// 必须在选区覆盖层出现**之前**读 —— 覆盖层一旦拿到焦点，它就变成 MacShot 自己了。
    static var frontmostApplication: NSRunningApplication? {
        NSWorkspace.shared.frontmostApplication
    }
}
