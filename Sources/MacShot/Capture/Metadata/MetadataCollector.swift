import AppKit
import Foundation

struct CaptureMetadata {
    var globalRegion: CGRect = .zero
    var scale: Double = 2.0

    var appName: String?
    var appBundleID: String?
    var appVersion: String?
    var appBuild: String?
    var windowTitle: String?
    var sourceURL: String?

    var displayID: CGDirectDisplayID?
    var displayName: String?
}

enum MetadataCollector {

    /// 采集来源信息。
    /// - Parameter fallbackApp: 在选区覆盖层弹出「之前」记录的前台 App —— 覆盖层一旦拿到焦点，
    ///   `frontmostApplication` 就变成我们自己了，所以必须提前取。
    @MainActor
    static func collect(
        region: CGRect,
        display: DisplayInfo,
        window: WindowInfo?,
        fallbackApp: NSRunningApplication?
    ) -> CaptureMetadata {
        var meta = CaptureMetadata()
        meta.globalRegion = region
        meta.scale = Double(display.scale)
        meta.displayID = display.id
        meta.displayName = display.name

        let runningApp: NSRunningApplication? = {
            if let pid = window?.pid, let app = NSRunningApplication(processIdentifier: pid) {
                return app
            }
            return fallbackApp
        }()

        meta.appName = runningApp?.localizedName ?? window?.ownerName
        meta.appBundleID = runningApp?.bundleIdentifier
        meta.windowTitle = window?.title

        if let bundleURL = runningApp?.bundleURL,
           let info = Bundle(url: bundleURL)?.infoDictionary {
            meta.appVersion = info["CFBundleShortVersionString"] as? String
            meta.appBuild = info["CFBundleVersion"] as? String
        }

        // 注意：浏览器地址**不在这里取**。Apple Event 是同步 IPC，会阻塞主线程，
        // 由 BrowserURLQueue 在截图落库之后异步回填。见 BrowserURLResolver。
        return meta
    }

    /// 捕获信息层的「App 名+版本」：按窗口归因的 pid 查在跑的 App，
    /// 版本从其 bundle 读；查不到退回 CGWindowList 的 ownerName。
    /// 都是内存操作，只在开启效果时取一次。
    ///
    /// 平台读取（NSRunningApplication/Bundle）统一收在这里，
    /// 域层其它地方不再直接摸。
    @MainActor
    static func appDescription(for window: WindowInfo?) -> String? {
        guard let window else { return nil }
        let runningApp = NSRunningApplication(processIdentifier: window.pid)
        let version = runningApp?.bundleURL
            .flatMap { Bundle(url: $0)?.infoDictionary?["CFBundleShortVersionString"] as? String }
        return CaptureInfoSpec.appDescription(
            name: runningApp?.localizedName ?? window.ownerName,
            version: version
        )
    }
}
