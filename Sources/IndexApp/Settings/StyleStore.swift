import Combine
import Foundation

// MARK: - StyleStore（全量设置接口 = 8 个窄协议的组合）
//
// 不再是独立的 ~40 属性宽清单，而是**继承 8 个领域窄协议**（`Preferences.swift`）
// 的组合。装配根（AppDelegate）持有 `any StyleStore`（全量）；各消费方只依赖它
// 真正读到的那一窄切片（`any CapturePreferences` 等），`any StyleStore` 可向上
// 转型成任意窄协议，所以注入点无需改动即可逐步迁移到窄类型。
@MainActor
protocol StyleStore: AnyObject, ObservableObject,
    CapturePreferences, RecordingPreferences, ExportPreferences,
    LibraryPreferences, AnnotationStylePreferences, IntelligencePreferences,
    UploadPreferences, ShortcutPreferences, ClipboardHistoryPreferences,
    PluginPreferences {}

extension AppSettings: StyleStore {}

// MARK: - FakeStyleStore (预览 / 单测替身)

/// 纯内存的设置替身，零 UserDefaults、零 I/O。
///
/// 与 `AppSettings` 一样持有 8 个领域偏好值类型，**默认值全部取自
/// `XxxPrefs.defaults`** —— 不再各抄一份，改默认值只改 `Prefs.swift` 一处。
/// 单测按领域传值（如 `FakeStyleStore(recording: .init(...))`）覆盖默认。
@MainActor
final class FakeStyleStore: ObservableObject, StyleStore,
    CapturePreferences, RecordingPreferences, ExportPreferences,
    LibraryPreferences, AnnotationStylePreferences, IntelligencePreferences,
    UploadPreferences, ShortcutPreferences, PluginPreferences {

    @Published var capture: CapturePrefs
    @Published var recording: RecordingPrefs
    @Published var export: ExportPrefs
    @Published var library: LibraryPrefs
    @Published var annotationStyle: AnnotationStylePrefs
    @Published var intelligence: IntelligencePrefs
    @Published var upload: UploadPrefs
    @Published var shortcuts: ShortcutPrefs
    @Published var clipboardHistory: ClipboardHistoryPrefs
    @Published var plugin: PluginPrefs

    init(
        capture: CapturePrefs = .defaults,
        recording: RecordingPrefs = .defaults,
        export: ExportPrefs = .defaults,
        library: LibraryPrefs = .defaults,
        annotationStyle: AnnotationStylePrefs = .defaults,
        intelligence: IntelligencePrefs = .defaults,
        upload: UploadPrefs = .defaults,
        shortcuts: ShortcutPrefs = .defaults,
        clipboardHistory: ClipboardHistoryPrefs = .defaults,
        plugin: PluginPrefs = .defaults
    ) {
        self.capture = capture
        self.recording = recording
        self.export = export
        self.library = library
        self.annotationStyle = annotationStyle
        self.intelligence = intelligence
        self.upload = upload
        self.shortcuts = shortcuts
        self.clipboardHistory = clipboardHistory
        self.plugin = plugin
    }

    // 转发到领域值（与 AppSettings 同一套窄协议 + StyleStore 契约）
    var copyToClipboard: Bool { capture.copyToClipboard }
    var showShelfCard: Bool { capture.showShelfCard }
    var enterBehavior: AppSettings.EnterBehavior { capture.enterBehavior }
    var showMagnifier: Bool { capture.showMagnifier }
    var windowCaptureShadow: Bool { capture.windowCaptureShadow }
    var captureDelay: Int { capture.captureDelay }
    var lastToolID: String? {
        get { capture.lastToolID }
        set { capture.lastToolID = newValue }
    }

    var recordSystemAudio: Bool { recording.recordSystemAudio }
    var recordMicrophone: Bool { recording.recordMicrophone }
    var recordingSaveToLibrary: Bool { recording.recordingSaveToLibrary }

    var exportNameTemplate: String { export.exportNameTemplate }
    var autoCopyEnabled: Bool { export.autoCopyEnabled }
    var autoCopyDirectory: String { export.autoCopyDirectory }

    var autoCleanupEnabled: Bool { library.autoCleanupEnabled }
    var autoCleanupDays: Int { library.autoCleanupDays }
    var galleryScrollDepth: Bool { library.galleryScrollDepth }

    var defaultColorIndex: Int { annotationStyle.defaultColorIndex }
    var defaultWidthIndex: Int { annotationStyle.defaultWidthIndex }
    var toolStyles: [String: ToolStyle] {
        get { annotationStyle.toolStyles }
        set { annotationStyle.toolStyles = newValue }
    }
    var watermarkText: String { annotationStyle.watermarkText }
    var trimmedWatermarkText: String { annotationStyle.watermarkText.trimmingCharacters(in: .whitespaces) }
    var watermarkMode: WatermarkMode { annotationStyle.watermarkMode }
    var watermarkAlpha: Double { annotationStyle.watermarkAlpha }
    var autoWatermark: Bool { annotationStyle.autoWatermark }
    var backdropPaddingRatio: Double { annotationStyle.backdropPaddingRatio }
    var backdropCornerRatio: Double { annotationStyle.backdropCornerRatio }
    var backdropShadowRatio: Double { annotationStyle.backdropShadowRatio }
    var backdropShadowAlpha: Double { annotationStyle.backdropShadowAlpha }
    var autoBackdrop: Bool { annotationStyle.autoBackdrop }

    var runOCR: Bool { intelligence.runOCR }
    var autoClassify: Bool { intelligence.autoClassify }
    var detectSensitive: Bool { intelligence.detectSensitive }
    var semanticSearch: Bool { intelligence.semanticSearch }
    var selectionAIBaseURL: String { intelligence.selectionAIBaseURL }
    var selectionAIModel: String { intelligence.selectionAIModel }

    var uploadEndpoint: String { upload.uploadEndpoint }
    var uploadFieldName: String { upload.uploadFieldName }
    var uploadHeaders: String { upload.uploadHeaders }
    var uploadResponsePath: String { upload.uploadResponsePath }
    var uploadLinkFormat: AppSettings.UploadLinkFormat { upload.uploadLinkFormat }

    var captureShortcut: KeyboardShortcut { shortcuts.captureShortcut }
    var galleryShortcut: KeyboardShortcut { shortcuts.galleryShortcut }
    var delayedCaptureShortcut: KeyboardShortcut { shortcuts.delayedCaptureShortcut }
    var recordingShortcut: KeyboardShortcut { shortcuts.recordingShortcut }
    var scrollCaptureShortcut: KeyboardShortcut { shortcuts.scrollCaptureShortcut }
    var moleculePinShortcut: KeyboardShortcut { shortcuts.moleculePinShortcut }
    var clipboardHistoryShortcut: KeyboardShortcut { shortcuts.clipboardHistoryShortcut }
    var searchPanelShortcut: KeyboardShortcut { shortcuts.searchPanelShortcut }
    var quickNoteShortcut: KeyboardShortcut { shortcuts.quickNoteShortcut }
    var agentShortcut: KeyboardShortcut { shortcuts.agentShortcut }

    var clipboardHistoryEnabled: Bool { clipboardHistory.enabled }
    var clipboardHistoryRetentionDays: Int { clipboardHistory.retentionDays }

    var enabledPluginIDs: [String] { plugin.enabledPluginIDs }
    var agentEnabled: Bool { plugin.agentEnabled }
    var agentBaseURL: String { plugin.agentBaseURL }
    var agentModel: String { plugin.agentModel }
    var agentAPIKey: String { plugin.agentAPIKey }
}