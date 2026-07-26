import AppKit
import Combine

/// 全部用户设置。`ObservableObject` 让 SwiftUI 直接绑定，
/// `didSet` 负责落盘和把变更推给需要的子系统（比如重新注册快捷键）。
@MainActor
final class AppSettings: ObservableObject {

    static let shared = AppSettings()

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

    private enum Keys {
        static let copyToClipboard = "copyToClipboard"
        static let runOCR = "runOCR"
        static let autoClassify = "autoClassify"
        static let detectSensitive = "detectSensitive"
        static let semanticSearch = "semanticSearch"
        static let showMagnifier = "showMagnifier"
        static let windowCaptureShadow = "windowCaptureShadow"
        static let enterBehavior = "enterBehavior"
        static let defaultColorIndex = "defaultColorIndex"
        static let defaultWidthIndex = "defaultWidthIndex"
        static let captureDelay = "captureDelay"
        static let captureShortcut = "captureShortcut"
        static let galleryShortcut = "galleryShortcut"
        static let delayedCaptureShortcut = "delayedCaptureShortcut"
        static let recordingShortcut = "recordingShortcut"
        static let scrollCaptureShortcut = "scrollCaptureShortcut"
        static let uploadEndpoint = "uploadEndpoint"
        static let uploadFieldName = "uploadFieldName"
        static let uploadHeaders = "uploadHeaders"
        static let uploadResponsePath = "uploadResponsePath"
        static let uploadLinkFormat = "uploadLinkFormat"
    }

    private let defaults = UserDefaults.standard

    // MARK: - 截图

    @Published var copyToClipboard: Bool {
        didSet { defaults.set(copyToClipboard, forKey: Keys.copyToClipboard) }
    }

    @Published var enterBehavior: EnterBehavior {
        didSet { defaults.set(enterBehavior.rawValue, forKey: Keys.enterBehavior) }
    }

    /// 选区时在光标旁显示像素放大镜和取色读数。
    @Published var showMagnifier: Bool {
        didSet { defaults.set(showMagnifier, forKey: Keys.showMagnifier) }
    }

    /// ⌥+单击的整窗截图是否带系统阴影（连同透明外沿一起输出）。
    @Published var windowCaptureShadow: Bool {
        didSet { defaults.set(windowCaptureShadow, forKey: Keys.windowCaptureShadow) }
    }

    /// 「延时截图」等待的秒数。
    static let captureDelayChoices = [3, 5, 10]

    @Published var captureDelay: Int {
        didSet { defaults.set(captureDelay, forKey: Keys.captureDelay) }
    }

    // MARK: - 标注默认值

    @Published var defaultColorIndex: Int {
        didSet { defaults.set(defaultColorIndex, forKey: Keys.defaultColorIndex) }
    }

    @Published var defaultWidthIndex: Int {
        didSet { defaults.set(defaultWidthIndex, forKey: Keys.defaultWidthIndex) }
    }

    // MARK: - 智能

    @Published var runOCR: Bool {
        didSet { defaults.set(runOCR, forKey: Keys.runOCR) }
    }

    /// 自动分类（规则分类 + Vision 场景标签）。
    @Published var autoClassify: Bool {
        didSet { defaults.set(autoClassify, forKey: Keys.autoClassify) }
    }

    /// 检测敏感内容（邮箱、密钥、卡号、手机号、人脸），供一键打码。
    @Published var detectSensitive: Bool {
        didSet { defaults.set(detectSensitive, forKey: Keys.detectSensitive) }
    }

    /// 语义搜索（MobileCLIP 向量）。默认关 —— 需要用户主动下载约 111 MB 模型。
    @Published var semanticSearch: Bool {
        didSet { defaults.set(semanticSearch, forKey: Keys.semanticSearch) }
    }

    // MARK: - 上传图床

    /// 图床上传接口地址。空 = 未配置，「上传」动作会提示先去设置。
    @Published var uploadEndpoint: String {
        didSet { defaults.set(uploadEndpoint, forKey: Keys.uploadEndpoint) }
    }

    /// multipart/form-data 里图片文件的字段名。PicGo / uPic 系图床通常是 "file"。
    @Published var uploadFieldName: String {
        didSet { defaults.set(uploadFieldName, forKey: Keys.uploadFieldName) }
    }

    /// 自定义请求头，每行一条 "Key: Value"。可能含 token，明文存 UserDefaults（与同类工具一致）。
    @Published var uploadHeaders: String {
        didSet { defaults.set(uploadHeaders, forKey: Keys.uploadHeaders) }
    }

    /// 从 JSON 响应里取链接的点分路径（如 "data.url"）。留空 = 整个响应体就是链接。
    @Published var uploadResponsePath: String {
        didSet { defaults.set(uploadResponsePath, forKey: Keys.uploadResponsePath) }
    }

    @Published var uploadLinkFormat: UploadLinkFormat {
        didSet { defaults.set(uploadLinkFormat.rawValue, forKey: Keys.uploadLinkFormat) }
    }

    // MARK: - 快捷键

    @Published var captureShortcut: KeyboardShortcut {
        didSet {
            store(captureShortcut, forKey: Keys.captureShortcut)
            onShortcutsChanged?()
        }
    }

    @Published var galleryShortcut: KeyboardShortcut {
        didSet {
            store(galleryShortcut, forKey: Keys.galleryShortcut)
            onShortcutsChanged?()
        }
    }

    @Published var delayedCaptureShortcut: KeyboardShortcut {
        didSet {
            store(delayedCaptureShortcut, forKey: Keys.delayedCaptureShortcut)
            onShortcutsChanged?()
        }
    }

    @Published var recordingShortcut: KeyboardShortcut {
        didSet {
            store(recordingShortcut, forKey: Keys.recordingShortcut)
            onShortcutsChanged?()
        }
    }

    @Published var scrollCaptureShortcut: KeyboardShortcut {
        didSet {
            store(scrollCaptureShortcut, forKey: Keys.scrollCaptureShortcut)
            onShortcutsChanged?()
        }
    }

    /// 由 AppDelegate 装上：快捷键一改就重新注册。
    var onShortcutsChanged: (() -> Void)?

    // MARK: -

    private init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [
            Keys.copyToClipboard: true,
            Keys.runOCR: true,
            Keys.autoClassify: true,
            Keys.detectSensitive: true,
            Keys.semanticSearch: false,
            Keys.showMagnifier: true,
            Keys.windowCaptureShadow: true,
            Keys.captureDelay: 3,
            Keys.enterBehavior: EnterBehavior.copyAndFinish.rawValue,
            Keys.defaultColorIndex: 0,
            Keys.defaultWidthIndex: 1,
            Keys.uploadEndpoint: "",
            Keys.uploadFieldName: "file",
            Keys.uploadHeaders: "",
            Keys.uploadResponsePath: "",
            Keys.uploadLinkFormat: UploadLinkFormat.raw.rawValue
        ])

        copyToClipboard = defaults.bool(forKey: Keys.copyToClipboard)
        runOCR = defaults.bool(forKey: Keys.runOCR)
        autoClassify = defaults.bool(forKey: Keys.autoClassify)
        detectSensitive = defaults.bool(forKey: Keys.detectSensitive)
        semanticSearch = defaults.bool(forKey: Keys.semanticSearch)
        showMagnifier = defaults.bool(forKey: Keys.showMagnifier)
        windowCaptureShadow = defaults.bool(forKey: Keys.windowCaptureShadow)
        captureDelay = defaults.integer(forKey: Keys.captureDelay)
        enterBehavior = defaults.string(forKey: Keys.enterBehavior)
            .flatMap(EnterBehavior.init(rawValue:)) ?? .copyAndFinish
        defaultColorIndex = defaults.integer(forKey: Keys.defaultColorIndex)
        defaultWidthIndex = defaults.integer(forKey: Keys.defaultWidthIndex)
        uploadEndpoint = defaults.string(forKey: Keys.uploadEndpoint) ?? ""
        uploadFieldName = defaults.string(forKey: Keys.uploadFieldName) ?? "file"
        uploadHeaders = defaults.string(forKey: Keys.uploadHeaders) ?? ""
        uploadResponsePath = defaults.string(forKey: Keys.uploadResponsePath) ?? ""
        uploadLinkFormat = defaults.string(forKey: Keys.uploadLinkFormat)
            .flatMap(UploadLinkFormat.init(rawValue:)) ?? .raw
        captureShortcut = Self.load(Keys.captureShortcut, from: defaults) ?? .captureDefault
        galleryShortcut = Self.load(Keys.galleryShortcut, from: defaults) ?? .galleryDefault
        delayedCaptureShortcut = Self.load(Keys.delayedCaptureShortcut, from: defaults)
            ?? .delayedCaptureDefault
        recordingShortcut = Self.load(Keys.recordingShortcut, from: defaults) ?? .recordingDefault
        scrollCaptureShortcut = Self.load(Keys.scrollCaptureShortcut, from: defaults)
            ?? .scrollCaptureDefault
    }

    func resetShortcuts() {
        captureShortcut = .captureDefault
        galleryShortcut = .galleryDefault
        delayedCaptureShortcut = .delayedCaptureDefault
        recordingShortcut = .recordingDefault
        scrollCaptureShortcut = .scrollCaptureDefault
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
