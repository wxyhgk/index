import AppKit
import Combine

/// 用户设置的聚合。
///
/// 持有 8 个**领域偏好**（`CapturePrefs` 等值类型，各自持久化），并 conform
/// 8 个窄读协议（`CapturePreferences` 等）—— 各消费方只依赖它读到的那一领域
/// 切片，而不是整个设置对象。
///
/// 默认值的**单一真相源**在 `Prefs.swift` 的 `XxxPrefs.defaults`：本类的
/// `register` 块与 `FakeStyleStore` 都从那里取默认值，不再各自抄一份。
///
/// 持久化沿用**按属性的 UserDefaults 键**（不引入新 blob 键），升级不丢用户
/// 已保存的设置；`@Published` 领域值驱动设置 UI 绑定，`didSet` 落盘。
@MainActor
final class AppSettings: ObservableObject {

    static let shared = AppSettings()

    // MARK: - 枚举（设置形状的一部分，供 UI 选择器与值类型引用）

    /// 选区确认后按回车做什么。
    enum EnterBehavior: String, CaseIterable, Identifiable {
        case copyAndFinish
        case finishOnly

        var id: String { rawValue }

        var title: String {
            switch self {
            case .copyAndFinish: return "完成并复制"
            case .finishOnly:    return "完成（不复制）"
            }
        }

        var detail: String {
            switch self {
            case .copyAndFinish: return "结果放进剪贴板"
            case .finishOnly:    return "只入库，不动剪贴板"
            }
        }
    }

    /// 上传成功后放进剪贴板的链接格式。
    enum UploadLinkFormat: String, CaseIterable, Identifiable {
        case raw
        case markdown

        var id: String { rawValue }

        var title: String {
            switch self {
            case .raw:      return "纯链接"
            case .markdown: return "Markdown"
            }
        }

        func format(_ url: String) -> String {
            switch self {
            case .raw:      return url
            case .markdown: return "![](\(url))"
            }
        }
    }

    // MARK: - UserDefaults 键（沿用旧键名，升级不丢已保存设置）

    private enum Keys {
        static let copyToClipboard = "copyToClipboard"
        static let showShelfCard = "showShelfCard"
        static let enterBehavior = "enterBehavior"
        static let showMagnifier = "showMagnifier"
        static let windowCaptureShadow = "windowCaptureShadow"
        static let captureDelay = "captureDelay"
        static let lastToolID = "lastToolID"

        static let recordSystemAudio = "recordSystemAudio"
        static let recordMicrophone = "recordMicrophone"
        static let recordingSaveToLibrary = "recordingSaveToLibrary"

        static let exportNameTemplate = "exportNameTemplate"
        static let autoCopyEnabled = "autoCopyEnabled"
        static let autoCopyDirectory = "autoCopyDirectory"

        static let autoCleanupEnabled = "autoCleanupEnabled"
        static let autoCleanupDays = "autoCleanupDays"
        static let galleryScrollDepth = "galleryScrollDepth"

        static let defaultColorIndex = "defaultColorIndex"
        static let defaultWidthIndex = "defaultWidthIndex"
        static let toolStyles = "toolStyles"
        static let watermarkText = "watermarkText"
        static let watermarkMode = "watermarkMode"
        static let watermarkAlpha = "watermarkAlpha"
        static let autoWatermark = "autoWatermark"
        static let backdropPaddingRatio = "backdropPaddingRatio"
        static let backdropCornerRatio = "backdropCornerRatio"
        static let backdropShadowRatio = "backdropShadowRatio"
        static let backdropShadowAlpha = "backdropShadowAlpha"
        static let autoBackdrop = "autoBackdrop"

        static let runOCR = "runOCR"
        static let autoClassify = "autoClassify"
        static let detectSensitive = "detectSensitive"
        static let semanticSearch = "semanticSearch"
        static let selectionAIBaseURL = "selectionAIBaseURL"
        static let selectionAIModel = "selectionAIModel"

        static let uploadEndpoint = "uploadEndpoint"
        static let uploadFieldName = "uploadFieldName"
        static let uploadHeaders = "uploadHeaders"
        static let uploadResponsePath = "uploadResponsePath"
        static let uploadLinkFormat = "uploadLinkFormat"

        static let captureShortcut = "captureShortcut"
        static let galleryShortcut = "galleryShortcut"
        static let delayedCaptureShortcut = "delayedCaptureShortcut"
        static let recordingShortcut = "recordingShortcut"
        static let scrollCaptureShortcut = "scrollCaptureShortcut"
        static let moleculePinShortcut = "moleculePinShortcut"
        static let clipboardHistoryShortcut = "clipboardHistoryShortcut"
        static let searchPanelShortcut = "searchPanelShortcut"
        static let quickNoteShortcut = "quickNoteShortcut"
        static let agentShortcut = "agentShortcut"

        static let clipboardHistoryEnabled = "clipboardHistoryEnabled"
        static let clipboardHistoryRetentionDays = "clipboardHistoryRetentionDays"

        static let enabledPluginIDs = "enabledPluginIDs"
        static let agentEnabled = "agentEnabled"
        static let agentBaseURL = "agentBaseURL"
        static let agentModel = "agentModel"
        static let agentAPIKey = "agentAPIKey"
    }

    private let defaults = UserDefaults.standard

    // MARK: - 领域偏好（@Published 驱动 UI 绑定，didSet 落盘）

    @Published var capture: CapturePrefs {
        didSet {
            defaults.set(capture.copyToClipboard, forKey: Keys.copyToClipboard)
            defaults.set(capture.showShelfCard, forKey: Keys.showShelfCard)
            defaults.set(capture.enterBehavior.rawValue, forKey: Keys.enterBehavior)
            defaults.set(capture.showMagnifier, forKey: Keys.showMagnifier)
            defaults.set(capture.windowCaptureShadow, forKey: Keys.windowCaptureShadow)
            defaults.set(capture.captureDelay, forKey: Keys.captureDelay)
            defaults.set(capture.lastToolID, forKey: Keys.lastToolID)
        }
    }

    @Published var recording: RecordingPrefs {
        didSet {
            defaults.set(recording.recordSystemAudio, forKey: Keys.recordSystemAudio)
            defaults.set(recording.recordMicrophone, forKey: Keys.recordMicrophone)
            defaults.set(recording.recordingSaveToLibrary, forKey: Keys.recordingSaveToLibrary)
        }
    }

    @Published var export: ExportPrefs {
        didSet {
            defaults.set(export.exportNameTemplate, forKey: Keys.exportNameTemplate)
            defaults.set(export.autoCopyEnabled, forKey: Keys.autoCopyEnabled)
            defaults.set(export.autoCopyDirectory, forKey: Keys.autoCopyDirectory)
        }
    }

    @Published var library: LibraryPrefs {
        didSet {
            defaults.set(library.autoCleanupEnabled, forKey: Keys.autoCleanupEnabled)
            defaults.set(library.autoCleanupDays, forKey: Keys.autoCleanupDays)
            defaults.set(library.galleryScrollDepth, forKey: Keys.galleryScrollDepth)
        }
    }

    @Published var annotationStyle: AnnotationStylePrefs {
        didSet {
            defaults.set(annotationStyle.defaultColorIndex, forKey: Keys.defaultColorIndex)
            defaults.set(annotationStyle.defaultWidthIndex, forKey: Keys.defaultWidthIndex)
            if let data = try? JSONEncoder().encode(annotationStyle.toolStyles) {
                defaults.set(String(data: data, encoding: .utf8), forKey: Keys.toolStyles)
            }
            defaults.set(annotationStyle.watermarkText, forKey: Keys.watermarkText)
            defaults.set(annotationStyle.watermarkMode.rawValue, forKey: Keys.watermarkMode)
            defaults.set(annotationStyle.watermarkAlpha, forKey: Keys.watermarkAlpha)
            defaults.set(annotationStyle.autoWatermark, forKey: Keys.autoWatermark)
            defaults.set(annotationStyle.backdropPaddingRatio, forKey: Keys.backdropPaddingRatio)
            defaults.set(annotationStyle.backdropCornerRatio, forKey: Keys.backdropCornerRatio)
            defaults.set(annotationStyle.backdropShadowRatio, forKey: Keys.backdropShadowRatio)
            defaults.set(annotationStyle.backdropShadowAlpha, forKey: Keys.backdropShadowAlpha)
            defaults.set(annotationStyle.autoBackdrop, forKey: Keys.autoBackdrop)
        }
    }

    @Published var intelligence: IntelligencePrefs {
        didSet {
            defaults.set(intelligence.runOCR, forKey: Keys.runOCR)
            defaults.set(intelligence.autoClassify, forKey: Keys.autoClassify)
            defaults.set(intelligence.detectSensitive, forKey: Keys.detectSensitive)
            defaults.set(intelligence.semanticSearch, forKey: Keys.semanticSearch)
            defaults.set(intelligence.selectionAIBaseURL, forKey: Keys.selectionAIBaseURL)
            defaults.set(intelligence.selectionAIModel, forKey: Keys.selectionAIModel)
        }
    }

    @Published var upload: UploadPrefs {
        didSet {
            defaults.set(upload.uploadEndpoint, forKey: Keys.uploadEndpoint)
            defaults.set(upload.uploadFieldName, forKey: Keys.uploadFieldName)
            defaults.set(upload.uploadHeaders, forKey: Keys.uploadHeaders)
            defaults.set(upload.uploadResponsePath, forKey: Keys.uploadResponsePath)
            defaults.set(upload.uploadLinkFormat.rawValue, forKey: Keys.uploadLinkFormat)
        }
    }

    @Published var shortcuts: ShortcutPrefs {
        didSet {
            store(shortcuts.captureShortcut, forKey: Keys.captureShortcut)
            store(shortcuts.galleryShortcut, forKey: Keys.galleryShortcut)
            store(shortcuts.delayedCaptureShortcut, forKey: Keys.delayedCaptureShortcut)
            store(shortcuts.recordingShortcut, forKey: Keys.recordingShortcut)
            store(shortcuts.scrollCaptureShortcut, forKey: Keys.scrollCaptureShortcut)
            store(shortcuts.moleculePinShortcut, forKey: Keys.moleculePinShortcut)
            store(shortcuts.clipboardHistoryShortcut, forKey: Keys.clipboardHistoryShortcut)
            store(shortcuts.agentShortcut, forKey: Keys.agentShortcut)
            onShortcutsChanged?()
        }
    }

    @Published var clipboardHistory: ClipboardHistoryPrefs {
        didSet {
            defaults.set(clipboardHistory.enabled, forKey: Keys.clipboardHistoryEnabled)
            defaults.set(clipboardHistory.retentionDays, forKey: Keys.clipboardHistoryRetentionDays)
            onClipboardHistoryChanged?()
        }
    }

    @Published var plugin: PluginPrefs {
        didSet {
            defaults.set(plugin.enabledPluginIDs, forKey: Keys.enabledPluginIDs)
            defaults.set(plugin.agentEnabled, forKey: Keys.agentEnabled)
            defaults.set(plugin.agentBaseURL, forKey: Keys.agentBaseURL)
            defaults.set(plugin.agentModel, forKey: Keys.agentModel)
            defaults.set(plugin.agentAPIKey, forKey: Keys.agentAPIKey)
        }
    }

    /// 由 AppDelegate 装上：剪贴板历史开关/保留策略变化时启停监听、清理。
    var onClipboardHistoryChanged: (() -> Void)?

    /// 由 AppDelegate 装上：快捷键一改就重新注册。
    var onShortcutsChanged: (() -> Void)?

    // MARK: - 装配

    private init() {
        // 默认值单一真相源：全部取自 XxxPrefs.defaults。
        defaults.register(defaults: [
            Keys.copyToClipboard: CapturePrefs.defaults.copyToClipboard,
            Keys.showShelfCard: CapturePrefs.defaults.showShelfCard,
            Keys.enterBehavior: CapturePrefs.defaults.enterBehavior.rawValue,
            Keys.showMagnifier: CapturePrefs.defaults.showMagnifier,
            Keys.windowCaptureShadow: CapturePrefs.defaults.windowCaptureShadow,
            Keys.captureDelay: CapturePrefs.defaults.captureDelay,

            Keys.recordSystemAudio: RecordingPrefs.defaults.recordSystemAudio,
            Keys.recordMicrophone: RecordingPrefs.defaults.recordMicrophone,
            Keys.recordingSaveToLibrary: RecordingPrefs.defaults.recordingSaveToLibrary,

            Keys.exportNameTemplate: ExportPrefs.defaults.exportNameTemplate,
            Keys.autoCopyEnabled: ExportPrefs.defaults.autoCopyEnabled,
            Keys.autoCopyDirectory: ExportPrefs.defaults.autoCopyDirectory,

            Keys.autoCleanupEnabled: LibraryPrefs.defaults.autoCleanupEnabled,
            Keys.autoCleanupDays: LibraryPrefs.defaults.autoCleanupDays,
            Keys.galleryScrollDepth: LibraryPrefs.defaults.galleryScrollDepth,

            Keys.defaultColorIndex: AnnotationStylePrefs.defaults.defaultColorIndex,
            Keys.defaultWidthIndex: AnnotationStylePrefs.defaults.defaultWidthIndex,
            Keys.watermarkText: AnnotationStylePrefs.defaults.watermarkText,
            Keys.watermarkMode: AnnotationStylePrefs.defaults.watermarkMode.rawValue,
            Keys.watermarkAlpha: AnnotationStylePrefs.defaults.watermarkAlpha,
            Keys.autoWatermark: AnnotationStylePrefs.defaults.autoWatermark,
            Keys.backdropPaddingRatio: AnnotationStylePrefs.defaults.backdropPaddingRatio,
            Keys.backdropCornerRatio: AnnotationStylePrefs.defaults.backdropCornerRatio,
            Keys.backdropShadowRatio: AnnotationStylePrefs.defaults.backdropShadowRatio,
            Keys.backdropShadowAlpha: AnnotationStylePrefs.defaults.backdropShadowAlpha,
            Keys.autoBackdrop: AnnotationStylePrefs.defaults.autoBackdrop,

            Keys.runOCR: IntelligencePrefs.defaults.runOCR,
            Keys.autoClassify: IntelligencePrefs.defaults.autoClassify,
            Keys.detectSensitive: IntelligencePrefs.defaults.detectSensitive,
            Keys.semanticSearch: IntelligencePrefs.defaults.semanticSearch,
            Keys.selectionAIBaseURL: IntelligencePrefs.defaults.selectionAIBaseURL,
            Keys.selectionAIModel: IntelligencePrefs.defaults.selectionAIModel,

            Keys.uploadEndpoint: UploadPrefs.defaults.uploadEndpoint,
            Keys.uploadFieldName: UploadPrefs.defaults.uploadFieldName,
            Keys.uploadHeaders: UploadPrefs.defaults.uploadHeaders,
            Keys.uploadResponsePath: UploadPrefs.defaults.uploadResponsePath,
            Keys.uploadLinkFormat: UploadPrefs.defaults.uploadLinkFormat.rawValue,

            Keys.clipboardHistoryEnabled: ClipboardHistoryPrefs.defaults.enabled,
            Keys.clipboardHistoryRetentionDays: ClipboardHistoryPrefs.defaults.retentionDays,

            Keys.enabledPluginIDs: PluginPrefs.defaults.enabledPluginIDs,
            Keys.agentEnabled: PluginPrefs.defaults.agentEnabled,
            Keys.agentBaseURL: PluginPrefs.defaults.agentBaseURL,
            Keys.agentModel: PluginPrefs.defaults.agentModel,
            Keys.agentAPIKey: PluginPrefs.defaults.agentAPIKey
        ])

        capture = CapturePrefs(
            copyToClipboard: defaults.bool(forKey: Keys.copyToClipboard),
            showShelfCard: defaults.bool(forKey: Keys.showShelfCard),
            enterBehavior: defaults.string(forKey: Keys.enterBehavior).flatMap(EnterBehavior.init(rawValue:)) ?? .copyAndFinish,
            showMagnifier: defaults.bool(forKey: Keys.showMagnifier),
            windowCaptureShadow: defaults.bool(forKey: Keys.windowCaptureShadow),
            captureDelay: defaults.integer(forKey: Keys.captureDelay),
            lastToolID: defaults.string(forKey: Keys.lastToolID)
        )
        recording = RecordingPrefs(
            recordSystemAudio: defaults.bool(forKey: Keys.recordSystemAudio),
            recordMicrophone: defaults.bool(forKey: Keys.recordMicrophone),
            recordingSaveToLibrary: defaults.bool(forKey: Keys.recordingSaveToLibrary)
        )
        export = ExportPrefs(
            exportNameTemplate: defaults.string(forKey: Keys.exportNameTemplate) ?? ExportPrefs.defaults.exportNameTemplate,
            autoCopyEnabled: defaults.bool(forKey: Keys.autoCopyEnabled),
            autoCopyDirectory: defaults.string(forKey: Keys.autoCopyDirectory) ?? ""
        )
        library = LibraryPrefs(
            autoCleanupEnabled: defaults.bool(forKey: Keys.autoCleanupEnabled),
            autoCleanupDays: defaults.integer(forKey: Keys.autoCleanupDays),
            galleryScrollDepth: defaults.bool(forKey: Keys.galleryScrollDepth)
        )
        annotationStyle = AnnotationStylePrefs(
            defaultColorIndex: defaults.integer(forKey: Keys.defaultColorIndex),
            defaultWidthIndex: defaults.integer(forKey: Keys.defaultWidthIndex),
            toolStyles: defaults.string(forKey: Keys.toolStyles)
                .flatMap { $0.data(using: .utf8) }
                .flatMap { try? JSONDecoder().decode([String: ToolStyle].self, from: $0) } ?? [:],
            watermarkText: defaults.string(forKey: Keys.watermarkText) ?? "",
            watermarkMode: defaults.string(forKey: Keys.watermarkMode).flatMap(WatermarkMode.init(rawValue:)) ?? .corner,
            watermarkAlpha: defaults.double(forKey: Keys.watermarkAlpha),
            autoWatermark: defaults.bool(forKey: Keys.autoWatermark),
            backdropPaddingRatio: defaults.double(forKey: Keys.backdropPaddingRatio),
            backdropCornerRatio: defaults.double(forKey: Keys.backdropCornerRatio),
            backdropShadowRatio: defaults.double(forKey: Keys.backdropShadowRatio),
            backdropShadowAlpha: defaults.double(forKey: Keys.backdropShadowAlpha),
            autoBackdrop: defaults.bool(forKey: Keys.autoBackdrop)
        )
        intelligence = IntelligencePrefs(
            runOCR: defaults.bool(forKey: Keys.runOCR),
            autoClassify: defaults.bool(forKey: Keys.autoClassify),
            detectSensitive: defaults.bool(forKey: Keys.detectSensitive),
            semanticSearch: defaults.bool(forKey: Keys.semanticSearch),
            selectionAIBaseURL: defaults.string(forKey: Keys.selectionAIBaseURL) ?? IntelligencePrefs.defaults.selectionAIBaseURL,
            selectionAIModel: defaults.string(forKey: Keys.selectionAIModel) ?? IntelligencePrefs.defaults.selectionAIModel
        )
        upload = UploadPrefs(
            uploadEndpoint: defaults.string(forKey: Keys.uploadEndpoint) ?? "",
            uploadFieldName: defaults.string(forKey: Keys.uploadFieldName) ?? "file",
            uploadHeaders: defaults.string(forKey: Keys.uploadHeaders) ?? "",
            uploadResponsePath: defaults.string(forKey: Keys.uploadResponsePath) ?? "",
            uploadLinkFormat: defaults.string(forKey: Keys.uploadLinkFormat).flatMap(UploadLinkFormat.init(rawValue:)) ?? .raw
        )
        shortcuts = ShortcutPrefs(
            captureShortcut: Self.load(Keys.captureShortcut, from: defaults) ?? .captureDefault,
            galleryShortcut: Self.load(Keys.galleryShortcut, from: defaults) ?? .galleryDefault,
            delayedCaptureShortcut: Self.load(Keys.delayedCaptureShortcut, from: defaults) ?? .delayedCaptureDefault,
            recordingShortcut: Self.load(Keys.recordingShortcut, from: defaults) ?? .recordingDefault,
            scrollCaptureShortcut: Self.load(Keys.scrollCaptureShortcut, from: defaults) ?? .scrollCaptureDefault,
            moleculePinShortcut: Self.load(Keys.moleculePinShortcut, from: defaults) ?? .moleculePinDefault,
            clipboardHistoryShortcut: Self.load(Keys.clipboardHistoryShortcut, from: defaults) ?? .clipboardHistoryDefault,
            searchPanelShortcut: Self.load(Keys.searchPanelShortcut, from: defaults) ?? .searchPanelDefault,
            quickNoteShortcut: Self.load(Keys.quickNoteShortcut, from: defaults) ?? .quickNoteDefault,
            agentShortcut: Self.load(Keys.agentShortcut, from: defaults) ?? .agentDefault
        )
        clipboardHistory = ClipboardHistoryPrefs(
            enabled: defaults.bool(forKey: Keys.clipboardHistoryEnabled),
            retentionDays: defaults.integer(forKey: Keys.clipboardHistoryRetentionDays)
        )
        plugin = PluginPrefs(
            enabledPluginIDs: defaults.stringArray(forKey: Keys.enabledPluginIDs) ?? PluginPrefs.defaults.enabledPluginIDs,
            agentEnabled: defaults.bool(forKey: Keys.agentEnabled),
            agentBaseURL: defaults.string(forKey: Keys.agentBaseURL) ?? PluginPrefs.defaults.agentBaseURL,
            agentModel: defaults.string(forKey: Keys.agentModel) ?? PluginPrefs.defaults.agentModel,
            agentAPIKey: defaults.string(forKey: Keys.agentAPIKey) ?? ""
        )
    }

    func resetShortcuts() {
        shortcuts = ShortcutPrefs.defaults
    }

    private func store(_ shortcut: KeyboardShortcut, forKey key: String) {
        guard let data = try? JSONEncoder().encode(shortcut) else { return }
        defaults.set(data, forKey: key)
    }

    private static func load(_ key: String, from defaults: UserDefaults) -> KeyboardShortcut? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(KeyboardShortcut.self, from: data)
    }
}

// MARK: - 窄读协议 conformance（转发到领域值）
//
// 这些只读转发同时满足 8 个窄协议与旧的宽 `StyleStore`（过渡期两者并存，
// 阶段 4 迁完消费方后删掉 StyleStore 与其转发）。唯一可写的是 toolStyles
// （AnnotationState 回写逐工具样式）。

extension AppSettings: CapturePreferences, RecordingPreferences, ExportPreferences,
    LibraryPreferences, AnnotationStylePreferences, IntelligencePreferences,
    UploadPreferences, ShortcutPreferences, PluginPreferences {

    // Capture
    var copyToClipboard: Bool { capture.copyToClipboard }
    var showShelfCard: Bool { capture.showShelfCard }
    var enterBehavior: EnterBehavior { capture.enterBehavior }
    var showMagnifier: Bool { capture.showMagnifier }
    var windowCaptureShadow: Bool { capture.windowCaptureShadow }
    var captureDelay: Int { capture.captureDelay }
    var lastToolID: String? {
        get { capture.lastToolID }
        set { capture.lastToolID = newValue }
    }

    // Recording
    var recordSystemAudio: Bool { recording.recordSystemAudio }
    var recordMicrophone: Bool { recording.recordMicrophone }
    var recordingSaveToLibrary: Bool { recording.recordingSaveToLibrary }

    // Export
    var exportNameTemplate: String { export.exportNameTemplate }
    var autoCopyEnabled: Bool { export.autoCopyEnabled }
    var autoCopyDirectory: String { export.autoCopyDirectory }

    // Library
    var autoCleanupEnabled: Bool { library.autoCleanupEnabled }
    var autoCleanupDays: Int { library.autoCleanupDays }
    var galleryScrollDepth: Bool { library.galleryScrollDepth }

    // AnnotationStyle
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

    // Intelligence
    var runOCR: Bool { intelligence.runOCR }
    var autoClassify: Bool { intelligence.autoClassify }
    var detectSensitive: Bool { intelligence.detectSensitive }
    var semanticSearch: Bool { intelligence.semanticSearch }
    var selectionAIBaseURL: String { intelligence.selectionAIBaseURL }
    var selectionAIModel: String { intelligence.selectionAIModel }

    // Upload
    var uploadEndpoint: String { upload.uploadEndpoint }
    var uploadFieldName: String { upload.uploadFieldName }
    var uploadHeaders: String { upload.uploadHeaders }
    var uploadResponsePath: String { upload.uploadResponsePath }
    var uploadLinkFormat: UploadLinkFormat { upload.uploadLinkFormat }

    // Shortcut
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

    // Plugin
    var enabledPluginIDs: [String] { plugin.enabledPluginIDs }
    var agentEnabled: Bool { plugin.agentEnabled }
    var agentBaseURL: String { plugin.agentBaseURL }
    var agentModel: String { plugin.agentModel }
    var agentAPIKey: String { plugin.agentAPIKey }
}