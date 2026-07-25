import AppKit
import ScreenCaptureKit
import CoreGraphics

enum CaptureError: Error, LocalizedError {
    case noPermission
    case displayNotFound
    case windowNotFound
    case emptyRegion

    var errorDescription: String? {
        switch self {
        case .noPermission: return "缺少「屏幕录制」权限"
        case .displayNotFound: return "找不到对应的显示器"
        case .windowNotFound: return "找不到目标窗口"
        case .emptyRegion: return "选区为空"
        }
    }
}

/// 基于 ScreenCaptureKit 的捕获。
/// 不使用 CGWindowListCreateImage —— 它在 macOS 14+ 已废弃且拿不到完整内容。
enum CaptureEngine {

    static func hasPermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    @discardableResult
    static func requestPermission() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    /// 截取一块屏幕区域。我们自己的进程会被排除在外，所以选区覆盖层不会出现在结果里。
    @MainActor
    static func capture(globalRect rect: CGRect, on screen: NSScreen) async throws -> CGImage {
        guard rect.width >= 1, rect.height >= 1 else { throw CaptureError.emptyRegion }
        guard hasPermission() else { throw CaptureError.noPermission }
        guard let targetID = Geometry.displayID(of: screen) else { throw CaptureError.displayNotFound }

        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        guard let display = content.displays.first(where: { $0.displayID == targetID }) else {
            throw CaptureError.displayNotFound
        }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        let ownApps = content.applications.filter { $0.processID == ownPID }
        let filter = SCContentFilter(
            display: display,
            excludingApplications: ownApps,
            exceptingWindows: []
        )

        let local = Geometry.displayLocalRect(globalAppKit: rect, on: screen)
        let scale = screen.backingScaleFactor

        let config = SCStreamConfiguration()
        config.sourceRect = local
        config.width = Int((local.width * scale).rounded())
        config.height = Int((local.height * scale).rounded())
        config.scalesToFit = false
        config.showsCursor = false
        config.captureResolution = .best
        config.ignoreShadowsDisplay = true

        return try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: config
        )
    }

    /// 整窗截图（含窗口外的阴影会被裁掉）。
    @MainActor
    static func captureWindow(windowID: CGWindowID, scale: CGFloat) async throws -> CGImage {
        guard hasPermission() else { throw CaptureError.noPermission }

        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
            throw CaptureError.windowNotFound
        }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        config.width = Int((window.frame.width * scale).rounded())
        config.height = Int((window.frame.height * scale).rounded())
        config.showsCursor = false
        config.captureResolution = .best
        config.ignoreShadowsSingleWindow = true

        return try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: config
        )
    }
}
