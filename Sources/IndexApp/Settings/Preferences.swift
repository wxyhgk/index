import Foundation

// MARK: - 领域读侧协议（窄边界）
//
// 取代原先那个 ~40 属性的宽 `StyleStore`：每个消费方只依赖它真正读到的那一
// 个领域切片，而不是整个设置对象。生产由 `AppSettings`（聚合，conform 全部）
// 满足；预览/单测用小 class 替身（从 `XxxPrefs.defaults` 构造，无 UserDefaults）。
//
// 都是只读值视图 —— 消费方不观察变更（观察是设置 UI 的职责），所以不要求
// ObservableObject。两个例外：`AnnotationStylePreferences.toolStyles` 可写
// （`AnnotationState` 回写逐工具样式）、`CapturePreferences.lastToolID` 可写
// （覆盖层回写「上次使用的工具」）。

protocol CapturePreferences: AnyObject {
    var copyToClipboard: Bool { get }
    var showShelfCard: Bool { get }
    var enterBehavior: AppSettings.EnterBehavior { get }
    var showMagnifier: Bool { get }
    var windowCaptureShadow: Bool { get }
    var captureDelay: Int { get }
    var lastToolID: String? { get set }
}

protocol RecordingPreferences: AnyObject {
    var recordSystemAudio: Bool { get }
    var recordMicrophone: Bool { get }
    var recordingSaveToLibrary: Bool { get }
}

protocol ExportPreferences: AnyObject {
    var exportNameTemplate: String { get }
    var autoCopyEnabled: Bool { get }
    var autoCopyDirectory: String { get }
}

protocol LibraryPreferences: AnyObject {
    var autoCleanupEnabled: Bool { get }
    var autoCleanupDays: Int { get }
    var galleryScrollDepth: Bool { get }
}

protocol AnnotationStylePreferences: AnyObject {
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
}

protocol IntelligencePreferences: AnyObject {
    var runOCR: Bool { get }
    var autoClassify: Bool { get }
    var detectSensitive: Bool { get }
    var semanticSearch: Bool { get }
    var selectionAIBaseURL: String { get }
    var selectionAIModel: String { get }
}

protocol UploadPreferences: AnyObject {
    var uploadEndpoint: String { get }
    var uploadFieldName: String { get }
    var uploadHeaders: String { get }
    var uploadResponsePath: String { get }
    var uploadLinkFormat: AppSettings.UploadLinkFormat { get }
}

protocol ShortcutPreferences: AnyObject {
    var captureShortcut: KeyboardShortcut { get }
    var galleryShortcut: KeyboardShortcut { get }
    var delayedCaptureShortcut: KeyboardShortcut { get }
    var recordingShortcut: KeyboardShortcut { get }
    var scrollCaptureShortcut: KeyboardShortcut { get }
    var moleculePinShortcut: KeyboardShortcut { get }
    var clipboardHistoryShortcut: KeyboardShortcut { get }
    var searchPanelShortcut: KeyboardShortcut { get }
    var quickNoteShortcut: KeyboardShortcut { get }
    var agentShortcut: KeyboardShortcut { get }
}

protocol ClipboardHistoryPreferences: AnyObject {
    var clipboardHistoryEnabled: Bool { get }
    var clipboardHistoryRetentionDays: Int { get }
}

protocol PluginPreferences: AnyObject {
    var enabledPluginIDs: [String] { get }
    var agentEnabled: Bool { get }
    var agentBaseURL: String { get }
    var agentModel: String { get }
    var agentAPIKey: String { get }
}