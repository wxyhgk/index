import Combine
import Foundation

// MARK: - StyleStore
//
// 样式与展示偏好的读侧契约。Gallery / Shelf / Editor 的视图与状态机不再直接读
// `AppSettings.shared`，改为依赖此协议——前者是 UI 预览与单测可注入的缝：
//
//   * 生产：`AppSettings.shared`（已在下方 `extension AppSettings: StyleStore` 声明一致性）
//   * 预览/测试：`FakeStyleStore`（纯内存，无 UserDefaults，无 I/O）
//   * 未来：可由 EnvironmentObject 全局提供，进一步收敛 AppSettings 的表面积
//
// 为什么叫 StyleStore 而非 SettingsStore：调用方只关心“样式/展示”这一子集
// （toolStyles、backdrop 比例、水印文案、gallery 展示开关、语义搜索开关、
// 上传配置），截图/录屏/存储等领域设置不在此合约内，保持最小暴露面。
@MainActor
protocol StyleStore: AnyObject, ObservableObject {
    var galleryScrollDepth: Bool { get }
    var semanticSearch: Bool { get }
    var runOCR: Bool { get }
    var autoClassify: Bool { get }
    var detectSensitive: Bool { get }

    var uploadEndpoint: String { get }
    var uploadFieldName: String { get }
    var uploadHeaders: String { get }
    var uploadResponsePath: String { get }
    var uploadLinkFormat: AppSettings.UploadLinkFormat { get }

    var defaultColorIndex: Int { get }
    var defaultWidthIndex: Int { get }
    var toolStyles: [String: ToolStyle] { get set }

    var watermarkText: String { get }
    var trimmedWatermarkText: String { get }
    var watermarkMode: WatermarkMode { get }
    var watermarkAlpha: Double { get }
    var autoWatermark: Bool { get }

    var backdropPaddingRatio: Double { get }
    var backdropCornerRatio: Double { get }
    var backdropShadowRatio: Double { get }
    var backdropShadowAlpha: Double { get }
    var autoBackdrop: Bool { get }

    var captureDelay: Int { get }
    var windowCaptureShadow: Bool { get }
    var copyToClipboard: Bool { get }
    var showShelfCard: Bool { get }
    var autoCopyEnabled: Bool { get }
    var autoCopyDirectory: String { get }
    var autoCleanupEnabled: Bool { get }
    var autoCleanupDays: Int { get }
    var recordingSaveToLibrary: Bool { get }
    var showMagnifier: Bool { get }

    var captureShortcut: KeyboardShortcut { get }
    var galleryShortcut: KeyboardShortcut { get }
    var delayedCaptureShortcut: KeyboardShortcut { get }
    var recordingShortcut: KeyboardShortcut { get }
    var scrollCaptureShortcut: KeyboardShortcut { get }
    var moleculePinShortcut: KeyboardShortcut { get }
}

extension AppSettings: StyleStore {}

// MARK: - FakeStyleStore (预览 / 单测替身)

/// 纯内存的 StyleStore 实现，零 UserDefaults、零 I/O。
/// 默认值与 `AppSettings.registerDefaults` 保持一致，预览可直接使用
/// `FakeStyleStore()` 无需额外配置；单测可按需改写。
@MainActor
final class FakeStyleStore: ObservableObject, StyleStore {

    @Published var galleryScrollDepth: Bool = true
    @Published var semanticSearch: Bool = false
    @Published var runOCR: Bool = true
    @Published var autoClassify: Bool = true
    @Published var detectSensitive: Bool = true

    @Published var uploadEndpoint: String = ""
    @Published var uploadFieldName: String = "file"
    @Published var uploadHeaders: String = ""
    @Published var uploadResponsePath: String = ""
    @Published var uploadLinkFormat: AppSettings.UploadLinkFormat = .raw

    @Published var defaultColorIndex: Int = 0
    @Published var defaultWidthIndex: Int = 1
    @Published var toolStyles: [String: ToolStyle] = [:]

    @Published var watermarkText: String = ""
    var trimmedWatermarkText: String {
        watermarkText.trimmingCharacters(in: .whitespaces)
    }
    @Published var watermarkMode: WatermarkMode = .corner
    @Published var watermarkAlpha: Double = 0.35
    @Published var autoWatermark: Bool = false

    @Published var backdropPaddingRatio: Double = 0.05
    @Published var backdropCornerRatio: Double = 0.014
    @Published var backdropShadowRatio: Double = 0.022
    @Published var backdropShadowAlpha: Double = 0.30
    @Published var autoBackdrop: Bool = false

    @Published var captureDelay: Int = 3
    @Published var windowCaptureShadow: Bool = true
    @Published var copyToClipboard: Bool = true
    @Published var showShelfCard: Bool = true
    @Published var autoCopyEnabled: Bool = false
    @Published var autoCopyDirectory: String = ""
    @Published var autoCleanupEnabled: Bool = false
    @Published var autoCleanupDays: Int = 30
    @Published var recordingSaveToLibrary: Bool = true
    @Published var showMagnifier: Bool = true

    @Published var captureShortcut: KeyboardShortcut = .captureDefault
    @Published var galleryShortcut: KeyboardShortcut = .galleryDefault
    @Published var delayedCaptureShortcut: KeyboardShortcut = .delayedCaptureDefault
    @Published var recordingShortcut: KeyboardShortcut = .recordingDefault
    @Published var scrollCaptureShortcut: KeyboardShortcut = .scrollCaptureDefault
    @Published var moleculePinShortcut: KeyboardShortcut = .moleculePinDefault

    init(
        galleryScrollDepth: Bool = true,
        semanticSearch: Bool = false,
        runOCR: Bool = true,
        autoClassify: Bool = true,
        detectSensitive: Bool = true,
        uploadEndpoint: String = "",
        toolStyles: [String: ToolStyle] = [:],
        watermarkText: String = "",
        watermarkMode: WatermarkMode = .corner,
        watermarkAlpha: Double = 0.35,
        autoWatermark: Bool = false,
        backdropPaddingRatio: Double = 0.05,
        backdropCornerRatio: Double = 0.014,
        backdropShadowRatio: Double = 0.022,
        backdropShadowAlpha: Double = 0.30,
        autoBackdrop: Bool = false,
        captureDelay: Int = 3,
        windowCaptureShadow: Bool = true,
        copyToClipboard: Bool = true,
        showShelfCard: Bool = true,
        autoCopyEnabled: Bool = false,
        autoCopyDirectory: String = "",
        autoCleanupEnabled: Bool = false,
        autoCleanupDays: Int = 30,
        recordingSaveToLibrary: Bool = false,
        showMagnifier: Bool = true,
        captureShortcut: KeyboardShortcut = .captureDefault,
        galleryShortcut: KeyboardShortcut = .galleryDefault,
        delayedCaptureShortcut: KeyboardShortcut = .delayedCaptureDefault,
        recordingShortcut: KeyboardShortcut = .recordingDefault,
        scrollCaptureShortcut: KeyboardShortcut = .scrollCaptureDefault,
        moleculePinShortcut: KeyboardShortcut = .moleculePinDefault
    ) {
        self.galleryScrollDepth = galleryScrollDepth
        self.semanticSearch = semanticSearch
        self.runOCR = runOCR
        self.autoClassify = autoClassify
        self.detectSensitive = detectSensitive
        self.uploadEndpoint = uploadEndpoint
        self.toolStyles = toolStyles
        self.watermarkText = watermarkText
        self.watermarkMode = watermarkMode
        self.watermarkAlpha = watermarkAlpha
        self.autoWatermark = autoWatermark
        self.backdropPaddingRatio = backdropPaddingRatio
        self.backdropCornerRatio = backdropCornerRatio
        self.backdropShadowRatio = backdropShadowRatio
        self.backdropShadowAlpha = backdropShadowAlpha
        self.autoBackdrop = autoBackdrop
        self.captureDelay = captureDelay
        self.windowCaptureShadow = windowCaptureShadow
        self.copyToClipboard = copyToClipboard
        self.showShelfCard = showShelfCard
        self.autoCopyEnabled = autoCopyEnabled
        self.autoCopyDirectory = autoCopyDirectory
        self.autoCleanupEnabled = autoCleanupEnabled
        self.autoCleanupDays = autoCleanupDays
        self.recordingSaveToLibrary = recordingSaveToLibrary
        self.showMagnifier = showMagnifier
        self.captureShortcut = captureShortcut
        self.galleryShortcut = galleryShortcut
        self.delayedCaptureShortcut = delayedCaptureShortcut
        self.recordingShortcut = recordingShortcut
        self.scrollCaptureShortcut = scrollCaptureShortcut
        self.moleculePinShortcut = moleculePinShortcut
    }
}
