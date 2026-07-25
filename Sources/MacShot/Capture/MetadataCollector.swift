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

    /// 已知支持 AppleScript 取地址的浏览器。Firefox 不支持（需退回 Accessibility），暂不处理。
    private static let chromiumBrowsers: Set<String> = [
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "com.microsoft.edgemac",
        "com.brave.Browser",
        "company.thebrowser.Browser",   // Arc
        "com.vivaldi.Vivaldi"
    ]
    private static let safariBrowsers: Set<String> = [
        "com.apple.Safari",
        "com.apple.SafariTechnologyPreview"
    ]

    static var isBrowserURLSupported: (String) -> Bool {
        { chromiumBrowsers.contains($0) || safariBrowsers.contains($0) }
    }

    /// 采集来源信息。
    /// - Parameter fallbackApp: 在选区覆盖层弹出「之前」记录的前台 App —— 覆盖层一旦拿到焦点，
    ///   `frontmostApplication` 就变成我们自己了，所以必须提前取。
    @MainActor
    static func collect(
        region: CGRect,
        screen: NSScreen?,
        window: WindowInfo?,
        fallbackApp: NSRunningApplication?
    ) -> CaptureMetadata {
        var meta = CaptureMetadata()
        meta.globalRegion = region
        meta.scale = Double(screen?.backingScaleFactor ?? 2.0)
        meta.displayID = screen.flatMap(Geometry.displayID(of:))
        meta.displayName = screen?.localizedName

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

        if let bundleID = meta.appBundleID, isBrowserURLSupported(bundleID) {
            meta.sourceURL = browserURL(bundleID: bundleID)
        }

        return meta
    }

    /// 通过 Apple Events 取当前标签页地址。
    /// 需要用户在「隐私与安全性 → 自动化」中授权；失败一律静默返回 nil，绝不阻塞截图流程。
    @MainActor
    private static func browserURL(bundleID: String) -> String? {
        let source: String
        if safariBrowsers.contains(bundleID) {
            source = """
            tell application id "\(bundleID)"
                if (count of documents) is 0 then return ""
                return URL of front document
            end tell
            """
        } else {
            source = """
            tell application id "\(bundleID)"
                if (count of windows) is 0 then return ""
                return URL of active tab of front window
            end tell
            """
        }

        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return nil }
        let result = script.executeAndReturnError(&error)
        if let error {
            NSLog("[MacShot] 取浏览器地址失败 (\(bundleID)): \(error)")
            return nil
        }
        let value = result.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (value?.isEmpty ?? true) ? nil : value
    }
}
