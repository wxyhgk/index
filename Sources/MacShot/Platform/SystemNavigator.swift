import AppKit

/// 跳转到系统的其它地方。收敛成一处，免得同一件事出现几种写法。
@MainActor
enum SystemNavigator {

    static func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
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
