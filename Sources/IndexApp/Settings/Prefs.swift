import Foundation

// MARK: - 领域偏好值类型
//
// 每个领域一个值类型，是「形状 + 默认值」的**单一真相源**。
// 持久化的 `AppSettings`（生产）与 `FakeStyleStore`（预览/单测）都从这里的
// `.defaults` 取默认值，不再各自抄一份 —— 改默认值只改这一处。
//
// 值类型本身不碰 UserDefaults、不碰 ObservableObject，纯数据，可 Equatable、
// 可跨层传递。持久化与观察由 `AppSettings` 的聚合层负责。

/// 截图行为：剪贴板、暂存卡、回车语义、放大镜、整窗阴影、延时、上次工具。
struct CapturePrefs: Equatable {
    var copyToClipboard: Bool
    var showShelfCard: Bool
    var enterBehavior: AppSettings.EnterBehavior
    var showMagnifier: Bool
    var windowCaptureShadow: Bool
    var captureDelay: Int
    /// 上次使用的标注工具（`AnnotationTool.id`）；nil = 从未用过 / 指针。
    var lastToolID: String?

    /// 「延时截图」可选秒数（UI 用）。
    static let captureDelayChoices = [3, 5, 10]

    static let defaults = CapturePrefs(
        copyToClipboard: true,
        showShelfCard: true,
        enterBehavior: .copyAndFinish,
        showMagnifier: true,
        windowCaptureShadow: true,
        captureDelay: 3,
        lastToolID: nil
    )
}

/// 录屏：系统音、麦克风、首帧入库。
struct RecordingPrefs: Equatable {
    var recordSystemAudio: Bool
    var recordMicrophone: Bool
    var recordingSaveToLibrary: Bool

    static let defaults = RecordingPrefs(
        recordSystemAudio: true,
        recordMicrophone: false,
        recordingSaveToLibrary: true
    )
}

/// 导出：文件名模板、自动副本。
struct ExportPrefs: Equatable {
    var exportNameTemplate: String
    var autoCopyEnabled: Bool
    var autoCopyDirectory: String

    static let defaults = ExportPrefs(
        exportNameTemplate: "{dateCompact}-{timeCompact}",
        autoCopyEnabled: false,
        autoCopyDirectory: ""
    )
}

/// 图库与存储：自动清理、逐卡滚动深度。
struct LibraryPrefs: Equatable {
    var autoCleanupEnabled: Bool
    var autoCleanupDays: Int
    var galleryScrollDepth: Bool

    /// 自动清理可选保留天数（UI 用）。
    static let autoCleanupChoices = [7, 30, 90]

    static let defaults = LibraryPrefs(
        autoCleanupEnabled: false,
        autoCleanupDays: 30,
        galleryScrollDepth: false
    )
}

/// 标注样式：默认颜色/粗细、逐工具样式、水印、自动美化。
struct AnnotationStylePrefs: Equatable {
    var defaultColorIndex: Int
    var defaultWidthIndex: Int
    var toolStyles: [String: ToolStyle]
    var watermarkText: String
    var watermarkMode: WatermarkMode
    var watermarkAlpha: Double
    var autoWatermark: Bool
    var backdropPaddingRatio: Double
    var backdropCornerRatio: Double
    var backdropShadowRatio: Double
    var backdropShadowAlpha: Double
    var autoBackdrop: Bool

    static let defaults = AnnotationStylePrefs(
        defaultColorIndex: 0,
        defaultWidthIndex: 1,
        toolStyles: [:],
        watermarkText: "",
        watermarkMode: .corner,
        watermarkAlpha: 0.35,
        autoWatermark: false,
        backdropPaddingRatio: 0.05,
        backdropCornerRatio: 0.014,
        backdropShadowRatio: 0.022,
        backdropShadowAlpha: 0.30,
        autoBackdrop: false
    )
}

/// 智能：OCR、分类、敏感检测、语义搜索、选区 AI 端点。
struct IntelligencePrefs: Equatable {
    var runOCR: Bool
    var autoClassify: Bool
    var detectSensitive: Bool
    var semanticSearch: Bool
    var selectionAIBaseURL: String
    var selectionAIModel: String

    static let defaults = IntelligencePrefs(
        runOCR: true,
        autoClassify: true,
        detectSensitive: true,
        semanticSearch: false,
        selectionAIBaseURL: "https://ai-api.wxyhgk.com/v1",
        selectionAIModel: "gpt-5.6-luna"
    )
}

/// 上传图床：端点、字段、请求头、响应路径、链接格式。
struct UploadPrefs: Equatable {
    var uploadEndpoint: String
    var uploadFieldName: String
    var uploadHeaders: String
    var uploadResponsePath: String
    var uploadLinkFormat: AppSettings.UploadLinkFormat

    static let defaults = UploadPrefs(
        uploadEndpoint: "",
        uploadFieldName: "file",
        uploadHeaders: "",
        uploadResponsePath: "",
        uploadLinkFormat: .raw
    )
}

/// 剪贴板历史：开关 + 保留天数。
struct ClipboardHistoryPrefs: Equatable {
    var enabled: Bool
    var retentionDays: Int

    /// 保留天数可选值（UI 用）。
    static let retentionChoices = [7, 30, 90]

    static let defaults = ClipboardHistoryPrefs(
        enabled: true,
        retentionDays: 30
    )
}

/// 插件管理：启停 + agent 配置。
///
/// 启用的插件 id 列表（不在列表里的插件不激活）。
/// agent 的 LLM 端点 / 模型 / API key（key 走 Keychain，这里只存引用名）。
struct PluginPrefs: Equatable {
    /// 已启用的插件 id（空 = 全部启用，内置默认）。
    var enabledPluginIDs: [String]
    /// agent 是否启用。
    var agentEnabled: Bool
    /// agent LLM 端点（OpenAI 兼容 /v1/chat/completions）。
    var agentBaseURL: String
    /// agent 模型名。
    var agentModel: String
    /// agent API key（当前明文存 UserDefaults，后续迁 Keychain）。
    var agentAPIKey: String

    static let defaults = PluginPrefs(
        enabledPluginIDs: [],
        agentEnabled: false,
        agentBaseURL: "https://ai-api.wxyhgk.com/v1",
        agentModel: "gpt-5.6-luna",
        agentAPIKey: ""
    )
}

/// 全局快捷键：可重绑的组合键。
struct ShortcutPrefs: Equatable {
    var captureShortcut: KeyboardShortcut
    var galleryShortcut: KeyboardShortcut
    var delayedCaptureShortcut: KeyboardShortcut
    var recordingShortcut: KeyboardShortcut
    var scrollCaptureShortcut: KeyboardShortcut
    var moleculePinShortcut: KeyboardShortcut
    var clipboardHistoryShortcut: KeyboardShortcut
    var searchPanelShortcut: KeyboardShortcut
    var quickNoteShortcut: KeyboardShortcut
    var agentShortcut: KeyboardShortcut

    static let defaults = ShortcutPrefs(
        captureShortcut: .captureDefault,
        galleryShortcut: .galleryDefault,
        delayedCaptureShortcut: .delayedCaptureDefault,
        recordingShortcut: .recordingDefault,
        scrollCaptureShortcut: .scrollCaptureDefault,
        moleculePinShortcut: .moleculePinDefault,
        clipboardHistoryShortcut: .clipboardHistoryDefault,
        searchPanelShortcut: .searchPanelDefault,
        quickNoteShortcut: .quickNoteDefault,
        agentShortcut: .agentDefault
    )
}