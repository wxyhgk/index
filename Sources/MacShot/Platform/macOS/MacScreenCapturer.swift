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
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            NSLog("[MacShot] SCShareableContent 失败: \(error)")
            throw error
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let ownApps = content.applications.filter { $0.processID == ownPID }
        var snapshots: [DisplaySnapshot] = []
        // 过滤已销毁的虚拟 display（如 spike 残留的 displayID 4），单屏失败不影响整批
        let validDisplayIDs = Set(content.displays.map(\.displayID))
        for screen in NSScreen.screens {
            guard let info = DisplayInfo(screen: screen) else { continue }
            guard validDisplayIDs.contains(info.id),
                  let display = content.displays.first(where: { $0.displayID == info.id })
            else {
                NSLog("[MacShot] 跳过无效 displayID=\(info.id) name=\(info.name)")
                continue
            }
            let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
            let config = SCStreamConfiguration()
            config.width = Int((info.frame.width * info.scale).rounded())
            config.height = Int((info.frame.height * info.scale).rounded())
            config.scalesToFit = false
            config.showsCursor = false
            config.captureResolution = .best
            config.ignoreShadowsDisplay = true
            config.colorSpaceName = CGColorSpace.sRGB
            do {
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                snapshots.append(DisplaySnapshot(display: info, image: image))
            } catch {
                NSLog("[MacShot] 单屏捕获失败 displayID=\(info.id) error=\(error)  跳过")
                continue
            }
        }
        guard !snapshots.isEmpty else {
            NSLog("[MacShot] 捕获失败：无可用 display（已跳过无效/失败的屏）")
            throw CaptureError.noDisplays
        }
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
