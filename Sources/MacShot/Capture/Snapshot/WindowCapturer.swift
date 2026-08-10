import AppKit
import ScreenCaptureKit

/// 整窗捕获：⌥+单击窗口时用 SCK 重拍**不被遮挡的完整窗口**。
///
/// `SCContentFilter(desktopIndependentWindow:)` 直接从窗口的后备存储取像素，
/// 别的窗口盖在上面也不影响 —— 这是冻结画面裁剪（所见即所得，含遮挡物）做不到的。
///
/// 输出带 alpha：`backgroundColor = .clear` 让窗口圆角外的像素真正透明；
/// 阴影由系统渲染（`ignoreShadowsSingleWindow` 控制），带阴影时 SCK 可能返回
/// 比请求尺寸大的位图 —— 实得尺寸记进日志，便于核对各系统版本的实际行为。
///
/// 刻意做成一次性的静态函数而不是 `CaptureSource`：它发生在选区**之后**，
/// 不产生冻结画布，也不参与覆盖层 —— 见 ARCHITECTURE §2.1 阶段 4 注。
enum WindowCapturer {

    @MainActor
    static func capture(
        windowID: CGWindowID,
        scale: CGFloat,
        includeShadow: Bool
    ) async throws -> CGImage {
        guard ScreenRecordingPermission.isGranted else { throw CaptureError.noPermission }

        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
            throw CaptureError.windowNotFound
        }

        let filter = SCContentFilter(desktopIndependentWindow: window)

        let config = SCStreamConfiguration()
        // 尺寸从 SCWindow.frame（点）乘倍率得像素。倍率取选区所在显示器的 ——
        // desktopIndependentWindow 的 filter 上拿不到可靠的 pointPixelScale。
        config.width = Int((window.frame.width * scale).rounded())
        config.height = Int((window.frame.height * scale).rounded())
        config.scalesToFit = false
        config.showsCursor = false
        config.captureResolution = .best
        config.ignoreShadowsSingleWindow = !includeShadow
        // 关键：窗口圆角外、以及阴影的半透明部分保持真透明，而不是合成到黑底上。
        config.backgroundColor = .clear
        config.colorSpaceName = CGColorSpace.sRGB

        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: config
        )

        // 带阴影时 SCK 自行决定外扩量，实得尺寸可能大于请求 —— 记录下来便于核对。
        NSLog(
            "[MacShot] 整窗捕获: 请求 %dx%d 实得 %dx%d 阴影=%@",
            config.width, config.height, image.width, image.height,
            includeShadow ? "带" : "无"
        )
        return image
    }
}
