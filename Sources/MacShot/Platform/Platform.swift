import AppKit
import CoreGraphics

// ============================================================
// MARK: - Platform PAL（平台抽象层）
//
// 目标：为 Windows 复用预留的骨架。上层只依赖协议，App 注入具体实现。
//
// 分层：
//   CSS 层  `UI/DesignTokens.swift`  → DS（视觉常量唯一入口）
//   API 层  `Platform/Platform.swift` → 本文件定义的 PAL 协议
//           `Platform/*.swift`       → macOS 实现（Mac* / 枚举单例）
//           未来 `WinClipboard` 等   → Windows 实现
//
// 边界规则（与 check.sh 纪律一呼应）：
//   - NSAlert / NSOpenPanel / NSSavePanel / runModal 只许出现在 Platform/
//     视图层通过 AppAlert / ImageExporter / SystemNavigator 间接使用。
//   - 新增平台能力先在 Platform.swift 加协议，再在 Mac* / Win* 各实现一个，
//     上层通过依赖注入持有协议，不直接 import AppKit 的具体类型。
//
// 现状：三条协议已落地（剪贴板 / 截图 / 钉图），其余 Platform/*（AppAlert、
// ImageExporter、SystemNavigator、WindowRegistry 等）已按「副作用收口」
// 收敛到 Platform/ 目录，下一步按需逐个抽协议即可，见下方预留表。
// ============================================================

/// 已落地的 PAL 协议（App 已可注入）。

@MainActor
protocol ClipboardWriting {
    func copy(text: String)
    func copy(_ image: CGImage)
    func copy(_ images: [CGImage])
}

@MainActor
protocol ScreenshotCapturing {
    func makeSnapshots() async throws -> [DisplaySnapshot]
}

/// 屏幕捕获抽象：把 ScreenCaptureKit / CGWindowListCreateImage 等 macOS 专有调用
/// 隔离在 Platform/macOS/，调用方只依赖此协议。
@MainActor
protocol ScreenCapturing {
    var isPermissionGranted: Bool { get }
    @discardableResult
    func requestPermission() -> Bool
    func captureDisplays() async throws -> [DisplaySnapshot]
    func captureWindow(windowID: CGWindowID, scale: CGFloat, includeShadow: Bool) async throws -> CGImage
}

/// 窗口列表抽象：把 CGWindowListCopyWindowInfo 隔离在 Platform/macOS/。
@MainActor
protocol WindowListing {
    func onScreenWindows(excludingPID pid: pid_t) -> [WindowInfo]
    func frontmostWindow(at point: CGPoint, excludingPID pid: pid_t) -> WindowInfo?
    func bestMatch(for region: CGRect, excludingPID pid: pid_t) -> WindowInfo?
}

@MainActor
protocol WindowPinning {
    func pin(image: CGImage, layers: Layers<ImageSpace>)
}

// ============================================================
// MARK: - 预留 PAL（下一步按需抽协议）
//
// 下表列出 Platform/ 目录现有能力的 PAL 映射，已有 macOS 实现，
// 协议名与未来 Win* 实现占位一并标注，新增时照此形状加一行即可。
//
// | 能力 | 现 macOS 实现 | 预留协议 | 未来 Win 实现 |
// |---|---|---|----|
// | 弹提示/确认框 | AppAlert | AlertPresenting | WinAlert |
// | 存盘面板+写 PNG | ImageExporter | FileExporting | WinFileExporter |
// | 目录选择/在访达中显示/打开 URL | SystemNavigator | SystemNavigating | WinSystemNavigator |
// | 窗口注册与前台管理 | WindowRegistry | WindowRegistryManaging | WinWindowRegistry |
// | 浏览器 URL 解析 | BrowserURLResolver | BrowserURLResolving | WinBrowserResolver |
// | 开机启动 | LaunchAtLogin | LaunchAtLoginManaging | WinLaunchAtLogin |
// | LiveText 分析 | LiveTextAnalyzer | LiveTextAnalyzing | WinLiveTextAnalyzer |
// | 面板摆放 | PanelPlacement | PanelPlacing | WinPanelPlacement |
// | 剪贴板 | Clipboard / MacClipboard | ClipboardWriting (已落地) | WinClipboard |
// | 屏幕捕获 | MacScreenCapturer | ScreenCapturing (已落地) | WinScreenCapturer |
// | 窗口列表 | MacWindowLister | WindowListing (已落地) | WinWindowLister |
//
// 约束：新增协议保持 @MainActor + 小接口（1–3 方法），避免把 AppKit 类型
// 泄漏到上层；CGImage / URL / String 等跨平台值类型优先。
// 边界总表见 Platform/README.md（macOS 专有符号零泄漏至 Capture/Overlay）。
// ============================================================

/// macOS 实现（现 `Clipboard` 的包装，未来 `WinClipboard` 另实现）
@MainActor
final class MacClipboard: ClipboardWriting {
    func copy(text: String) { Clipboard.copy(text: text) }
    func copy(_ image: CGImage) { Clipboard.copy(image) }
    func copy(_ images: [CGImage]) { Clipboard.copy(images) }
    static let shared = MacClipboard()
}
