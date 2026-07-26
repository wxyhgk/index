import AppKit
import ScreenCaptureKit
import CoreGraphics

enum CaptureError: Error, LocalizedError {
    case noPermission
    case noDisplays
    case cropFailed

    var errorDescription: String? {
        switch self {
        case .noPermission: return "缺少「屏幕录制」权限"
        case .noDisplays: return "没有找到可捕获的显示器"
        case .cropFailed: return "选区裁剪失败"
        }
    }
}

enum ScreenRecordingPermission {
    static var isGranted: Bool { CGPreflightScreenCaptureAccess() }

    @discardableResult
    static func request() -> Bool { CGRequestScreenCaptureAccess() }
}

/// 「立即截图」：按下快捷键立刻把屏幕定格成位图。
/// ScreenCaptureKit 实现 —— 不使用 CGWindowListCreateImage，它在 macOS 14+ 已废弃且拿不到完整内容。
struct ImmediateScreenSource: CaptureSource {

    let id = CaptureSourceID.immediate
    let title = "立即截图"
    let symbolName = "camera.viewfinder"

    func makeSnapshots() async throws -> [DisplaySnapshot] {
        guard ScreenRecordingPermission.isGranted else { throw CaptureError.noPermission }

        // 整个流程只查一次 SCShareableContent。之前是每次截图都查，窗口多时要几十到几百毫秒。
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )

        let ownPID = ProcessInfo.processInfo.processIdentifier
        let ownApps = content.applications.filter { $0.processID == ownPID }

        var snapshots: [DisplaySnapshot] = []
        for screen in NSScreen.screens {
            guard
                let info = DisplayInfo(screen: screen),
                let display = content.displays.first(where: { $0.displayID == info.id })
            else { continue }

            let filter = SCContentFilter(
                display: display,
                excludingApplications: ownApps,
                exceptingWindows: []
            )

            let config = SCStreamConfiguration()
            config.width = Int((info.frame.width * info.scale).rounded())
            config.height = Int((info.frame.height * info.scale).rounded())
            config.scalesToFit = false
            config.showsCursor = false
            config.captureResolution = .best
            config.ignoreShadowsDisplay = true
            // 显式锁定色彩空间，否则截 HDR / 广色域内容时颜色会漂。
            config.colorSpaceName = CGColorSpace.sRGB

            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: config
            )
            snapshots.append(DisplaySnapshot(display: info, image: image))
        }

        guard !snapshots.isEmpty else { throw CaptureError.noDisplays }
        return snapshots
    }
}
