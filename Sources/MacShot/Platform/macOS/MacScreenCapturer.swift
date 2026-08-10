import AppKit
import CoreGraphics
import ScreenCaptureKit

@MainActor
final class MacScreenCapturer: ScreenCapturing {

    static let shared = MacScreenCapturer()

    var isPermissionGranted: Bool { CGPreflightScreenCaptureAccess() }

    @discardableResult
    func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    func captureDisplays() async throws -> [DisplaySnapshot] {
        guard isPermissionGranted else { throw CaptureError.noPermission }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let ownApps = content.applications.filter { $0.processID == ownPID }
        var snapshots: [DisplaySnapshot] = []
        for screen in NSScreen.screens {
            guard let info = DisplayInfo(screen: screen),
                  let display = content.displays.first(where: { $0.displayID == info.id })
            else { continue }
            let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
            let config = SCStreamConfiguration()
            config.width = Int((info.frame.width * info.scale).rounded())
            config.height = Int((info.frame.height * info.scale).rounded())
            config.scalesToFit = false
            config.showsCursor = false
            config.captureResolution = .best
            config.ignoreShadowsDisplay = true
            config.colorSpaceName = CGColorSpace.sRGB
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            snapshots.append(DisplaySnapshot(display: info, image: image))
        }
        guard !snapshots.isEmpty else { throw CaptureError.noDisplays }
        return snapshots
    }

    func captureWindow(windowID: CGWindowID, scale: CGFloat, includeShadow: Bool) async throws -> CGImage {
        guard isPermissionGranted else { throw CaptureError.noPermission }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
            throw CaptureError.windowNotFound
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        config.width = Int((window.frame.width * scale).rounded())
        config.height = Int((window.frame.height * scale).rounded())
        config.scalesToFit = false
        config.showsCursor = false
        config.captureResolution = .best
        config.ignoreShadowsSingleWindow = !includeShadow
        config.backgroundColor = .clear
        config.colorSpaceName = CGColorSpace.sRGB
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        NSLog("[MacShot] 整窗捕获: 请求 %dx%d 实得 %dx%d 阴影=%@", config.width, config.height, image.width, image.height, includeShadow ? "带" : "无")
        return image
    }
}

enum CaptureError: Error, LocalizedError {
    case noPermission
    case noDisplays
    case windowNotFound
    case cropFailed
    var errorDescription: String? {
        switch self {
        case .noPermission: return "缺少「屏幕录制」权限"
        case .noDisplays: return "没有找到可捕获的显示器"
        case .windowNotFound: return "找不到目标窗口"
        case .cropFailed: return "选区裁剪失败"
        }
    }
}

@MainActor
enum ScreenRecordingPermission {
    static var isGranted: Bool { MacScreenCapturer.shared.isPermissionGranted }
    @discardableResult
    static func request() -> Bool { MacScreenCapturer.shared.requestPermission() }
}
