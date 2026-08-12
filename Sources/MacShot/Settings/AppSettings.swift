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
        static let showShelfCard = "showShelfCard"
        static let runOCR = "runOCR"
        static let autoClassify = "autoClassify"
        static let detectSensitive = "detectSensitive"
        static let semanticSearch = "semanticSearch"
        static let showMagnifier = "showMagnifier"
        static let windowCaptureShadow = "windowCaptureShadow"
        static let enterBehavior = "enterBehavior"
        static let defaultColorIndex = "defaultColorIndex"
        static let defaultWidthIndex = "defaultWidthIndex"
        static let toolStyles = "toolStyles"
        static let autoBackdrop = "autoBackdrop"
        // 存的是**短边百分比**而不是像素，见 `EffectRegistry.backdrop`。
        static let backdropPaddingRatio = "backdropPaddingRatio"
        static let backdropCornerRatio = "backdropCornerRatio"
        static let backdropShadowRatio = "backdropShadowRatio"
        static let backdropShadowAlpha = "backdropShadowAlpha"
        static let captureDelay = "captureDelay"
        static let captureShortcut = "captureShortcut"
        static let galleryShortcut = "galleryShortcut"
        static let delayedCaptureShortcut = "delayedCaptureShortcut"
        static let recordingShortcut = "recordingShortcut"
        static let scrollCaptureShortcut = "scrollCaptureShortcut"
        static let moleculePinShortcut = "moleculePinShortcut"
        static let watermarkText = "watermarkText"
        static let watermarkMode = "watermarkMode"
        static let watermarkAlpha = "watermarkAlpha"
        static let autoWatermark = "autoWatermark"
        static let uploadEndpoint = "uploadEndpoint"
        static let uploadFieldName = "uploadFieldName"
        static let uploadHeaders = "uploadHeaders"
        static let uploadResponsePath = "uploadResponsePath"
        static let uploadLinkFormat = "uploadLinkFormat"
        static let exportNameTemplate = "exportNameTemplate"
        static let autoCopyEnabled = "autoCopyEnabled"
        static let autoCopyDirectory = "autoCopyDirectory"
        static let autoCleanupEnabled = "autoCleanupEnabled"
        static let autoCleanupDays = "autoCleanupDays"
        static let recordSystemAudio = "recordSystemAudio"
        static let recordMicrophone = "recordMicrophone"
        static let recordingSaveToLibrary = "recordingSaveToLibrary"
        static let galleryScrollDepth = "galleryScrollDepth"
    }

    private let defaults = UserDefaults.standard

    // MARK: - 截图

    @Published var copyToClipboard: Bool {
        didSet { defaults.set(copyToClipboard, forKey: Keys.copyToClipboard) }
    }

    /// 截图后在屏幕右下角显示暂存卡片（可直接拖出成文件）。钉图动作不弹。
    @Published var showShelfCard: Bool {
        didSet { defaults.set(showShelfCard, forKey: Keys.showShelfCard) }
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

    // MARK: - 录屏

    /// 录制系统声音（App 播放的音频，MacShot 自身除外）。默认开。
    @Published var recordSystemAudio: Bool {
        didSet { defaults.set(recordSystemAudio, forKey: Keys.recordSystemAudio) }
    }

    /// 录制麦克风。默认关 —— 首次开启会触发系统麦克风权限弹窗。
    @Published var recordMicrophone: Bool {
        didSet { defaults.set(recordMicrophone, forKey: Keys.recordMicrophone) }
    }

    /// 录屏完成后把首帧截图入库当锚点（视频作为 recording 附件关联到 Shot）。
    /// 默认关 —— 图库目前是截图库，视频只是借首帧「能被找到」。
    @Published var recordingSaveToLibrary: Bool {
        didSet { defaults.set(recordingSaveToLibrary, forKey: Keys.recordingSaveToLibrary) }
    }

    // MARK: - 导出

    /// 导出文件名模板。变量：{dateCompact}/{timeCompact} 紧凑日期时间、
    /// {date}/{time} 可读日期时间、{app} 来源 App、{title} 窗口标题、{name} 显示名称。
    /// 渲染规则在 `ImageExporter.renderName`，这里只存模板本身。
    @Published var exportNameTemplate: String {
        didSet { defaults.set(exportNameTemplate, forKey: Keys.exportNameTemplate) }
    }

    static let defaultExportNameTemplate = "{dateCompact}-{timeCompact}"

    /// 自动保存副本：每张截图入库后往指定目录写一份成品 PNG。
    /// 面向 Obsidian 等监听文件夹的场景。
    @Published var autoCopyEnabled: Bool {
        didSet { defaults.set(autoCopyEnabled, forKey: Keys.autoCopyEnabled) }
    }

    /// 副本写入的目录路径。空 = 未选择，即使开关开着也不写。
    @Published var autoCopyDirectory: String {
        didSet { defaults.set(autoCopyDirectory, forKey: Keys.autoCopyDirectory) }
    }

    // MARK: - 存储清理

    /// 启动时自动清理旧截图。默认关 —— 删除是不可逆操作，必须用户主动开启。
    @Published var autoCleanupEnabled: Bool {
        didSet { defaults.set(autoCleanupEnabled, forKey: Keys.autoCleanupEnabled) }
    }

    static let autoCleanupChoices = [7, 30, 90]

    /// 保留天数。只有早于这个天数、未收藏且从未标注过的截图才会被清理。
    @Published var autoCleanupDays: Int {
        didSet { defaults.set(autoCleanupDays, forKey: Keys.autoCleanupDays) }
    }

    // MARK: - 图库

    /// 图库网格的逐卡滚动深度（滑近边缘时轻微淡出 + 缩小 + 位移）。默认开。
    /// 关掉只影响这一层「逐卡」效果，容器级的滚动边缘渐变（成本恒定，与卡片数无关）始终在。
    /// 给开关的理由是成本：逐卡 scrollTransition 的代价 ∝ 可见卡片数，
    /// 而 macOS 15 的 SwiftUI 滚动本身已有性能回归（trackpad 滚动时
    /// `_hitTestForEvent` 吃掉约 85% 执行时间），几千张的库应当把这一层关掉。
    @Published var galleryScrollDepth: Bool {
        didSet { defaults.set(galleryScrollDepth, forKey: Keys.galleryScrollDepth) }
    }

    // MARK: - 标注默认值

    @Published var defaultColorIndex: Int {
        didSet { defaults.set(defaultColorIndex, forKey: Keys.defaultColorIndex) }
    }

    @Published var defaultWidthIndex: Int {
        didSet { defaults.set(defaultWidthIndex, forKey: Keys.defaultWidthIndex) }
    }

    // MARK: - 自动美化（透明留白 + 圆角 + 投影）

    /// 截图后自动套一层「透明美化」：四周留出透明留白、内容切圆角、投一层柔和阴影。
    /// 只作用于**拖拽选区**的截图 —— 整窗截图（⌥+单击）走系统窗口阴影，
    /// 两者叠加会出现双重阴影。
    @Published var autoBackdrop: Bool {
        didSet { defaults.set(autoBackdrop, forKey: Keys.autoBackdrop) }
    }

    // 下面三项都是**图片短边的百分比**，不是绝对像素 ——
    // 绝对值在小图上会把内容淹掉、在大图上又几乎看不见，
    // 而且 Retina 与非 Retina 抓同一个窗口像素差一倍。换算与钳位见
    // `EffectRegistry.backdrop`。

    /// 四周留白占短边的比例。留白要装得下阴影，太小会把阴影切掉。
    @Published var backdropPaddingRatio: Double {
        didSet { defaults.set(backdropPaddingRatio, forKey: Keys.backdropPaddingRatio) }
    }

    /// 内容圆角半径占短边的比例。
    @Published var backdropCornerRatio: Double {
        didSet { defaults.set(backdropCornerRatio, forKey: Keys.backdropCornerRatio) }
    }

    /// 阴影模糊半径占短边的比例。
    @Published var backdropShadowRatio: Double {
        didSet { defaults.set(backdropShadowRatio, forKey: Keys.backdropShadowRatio) }
    }

    /// 阴影浓度 0…1。
    @Published var backdropShadowAlpha: Double {
        didSet { defaults.set(backdropShadowAlpha, forKey: Keys.backdropShadowAlpha) }
    }

    /// 每个工具单独记住的样式（键是 `AnnotationTool.id`）。
    ///
    /// 上面那两个全局默认降级为**首次使用的种子**：只作用于还没有单独偏好的工具。
    /// 存成 JSON 而不是逐项开一个 UserDefaults 键 —— 工具 × 样式轴是二维的，
    /// 摊平会变成几十个键，加一根轴就要改一次注册表。
    /// 解不出来（格式变更 / 手工改坏）就退回空字典，让描述符的默认值兜底。
    @Published var toolStyles: [String: ToolStyle] {
        didSet {
            guard let data = try? JSONEncoder().encode(toolStyles) else { return }
            defaults.set(String(data: data, encoding: .utf8), forKey: Keys.toolStyles)
        }
    }

    // MARK: - 水印

    /// 默认水印文案。空 = 未配置：「导出自动加水印」不生效，
    /// 手动开关（工具条/编辑器）用 "MacShot" 兜底。
    @Published var watermarkText: String {
        didSet { defaults.set(watermarkText, forKey: Keys.watermarkText) }
    }

    /// 默认水印位置（右下角 / 居中 / 平铺）。
    @Published var watermarkMode: WatermarkMode {
        didSet { defaults.set(watermarkMode.rawValue, forKey: Keys.watermarkMode) }
    }

    /// 水印透明度（0.1–0.8）。白字 + 细黑描边，深浅底上都可见。
    @Published var watermarkAlpha: Double {
        didSet { defaults.set(watermarkAlpha, forKey: Keys.watermarkAlpha) }
    }

    /// 新截图落库时自动追加一层水印。只作用于截图路径
    /// （`CaptureCoordinator.handle`），编辑器/钉图的手动开关不受它影响。
    @Published var autoWatermark: Bool {
        didSet { defaults.set(autoWatermark, forKey: Keys.autoWatermark) }
    }

    /// 去掉首尾空白后的水印文案；空串 = 未配置。
    var trimmedWatermarkText: String {
        watermarkText.trimmingCharacters(in: .whitespaces)
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

    @Published var moleculePinShortcut: KeyboardShortcut {
        didSet {
            store(moleculePinShortcut, forKey: Keys.moleculePinShortcut)
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
            Keys.showShelfCard: true,
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
            Keys.autoBackdrop: false,
            // 短边百分比。1000px 短边的图上约等于：留白 50 / 圆角 14 / 阴影 22 像素，
            // 与 iShot 那套观感接近；小图大图按同样比例缩放。
            Keys.backdropPaddingRatio: 0.05,
            Keys.backdropCornerRatio: 0.014,
            Keys.backdropShadowRatio: 0.022,
            Keys.backdropShadowAlpha: 0.30,
            Keys.watermarkText: "",
            Keys.watermarkMode: WatermarkMode.corner.rawValue,
            Keys.watermarkAlpha: 0.35,
            Keys.autoWatermark: false,
            Keys.uploadEndpoint: "",
            Keys.uploadFieldName: "file",
            Keys.uploadHeaders: "",
            Keys.uploadResponsePath: "",
            Keys.uploadLinkFormat: UploadLinkFormat.raw.rawValue,
            Keys.exportNameTemplate: Self.defaultExportNameTemplate,
            Keys.autoCopyEnabled: false,
            Keys.autoCopyDirectory: "",
            Keys.autoCleanupEnabled: false,
            Keys.autoCleanupDays: 30,
            Keys.recordSystemAudio: true,
            Keys.recordMicrophone: false,
            Keys.recordingSaveToLibrary: true,
            Keys.galleryScrollDepth: true
        ])

        copyToClipboard = defaults.bool(forKey: Keys.copyToClipboard)
        showShelfCard = defaults.bool(forKey: Keys.showShelfCard)
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
        autoBackdrop = defaults.bool(forKey: Keys.autoBackdrop)
        backdropPaddingRatio = defaults.double(forKey: Keys.backdropPaddingRatio)
        backdropCornerRatio = defaults.double(forKey: Keys.backdropCornerRatio)
        backdropShadowRatio = defaults.double(forKey: Keys.backdropShadowRatio)
        backdropShadowAlpha = defaults.double(forKey: Keys.backdropShadowAlpha)
        toolStyles = defaults.string(forKey: Keys.toolStyles)
            .flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONDecoder().decode([String: ToolStyle].self, from: $0) } ?? [:]
        watermarkText = defaults.string(forKey: Keys.watermarkText) ?? ""
        watermarkMode = defaults.string(forKey: Keys.watermarkMode)
            .flatMap(WatermarkMode.init(rawValue:)) ?? .corner
        watermarkAlpha = defaults.double(forKey: Keys.watermarkAlpha)
        autoWatermark = defaults.bool(forKey: Keys.autoWatermark)
        uploadEndpoint = defaults.string(forKey: Keys.uploadEndpoint) ?? ""
        uploadFieldName = defaults.string(forKey: Keys.uploadFieldName) ?? "file"
        uploadHeaders = defaults.string(forKey: Keys.uploadHeaders) ?? ""
        uploadResponsePath = defaults.string(forKey: Keys.uploadResponsePath) ?? ""
        uploadLinkFormat = defaults.string(forKey: Keys.uploadLinkFormat)
            .flatMap(UploadLinkFormat.init(rawValue:)) ?? .raw
        exportNameTemplate = defaults.string(forKey: Keys.exportNameTemplate)
            ?? Self.defaultExportNameTemplate
        autoCopyEnabled = defaults.bool(forKey: Keys.autoCopyEnabled)
        autoCopyDirectory = defaults.string(forKey: Keys.autoCopyDirectory) ?? ""
        autoCleanupEnabled = defaults.bool(forKey: Keys.autoCleanupEnabled)
        autoCleanupDays = defaults.integer(forKey: Keys.autoCleanupDays)
        recordSystemAudio = defaults.bool(forKey: Keys.recordSystemAudio)
        recordMicrophone = defaults.bool(forKey: Keys.recordMicrophone)
        recordingSaveToLibrary = defaults.bool(forKey: Keys.recordingSaveToLibrary)
        galleryScrollDepth = defaults.bool(forKey: Keys.galleryScrollDepth)
        captureShortcut = Self.load(Keys.captureShortcut, from: defaults) ?? .captureDefault
        galleryShortcut = Self.load(Keys.galleryShortcut, from: defaults) ?? .galleryDefault
        delayedCaptureShortcut = Self.load(Keys.delayedCaptureShortcut, from: defaults)
            ?? .delayedCaptureDefault
        recordingShortcut = Self.load(Keys.recordingShortcut, from: defaults) ?? .recordingDefault
        scrollCaptureShortcut = Self.load(Keys.scrollCaptureShortcut, from: defaults)
            ?? .scrollCaptureDefault
        moleculePinShortcut = Self.load(Keys.moleculePinShortcut, from: defaults)
            ?? .moleculePinDefault
    }

    func resetShortcuts() {
        captureShortcut = .captureDefault
        galleryShortcut = .galleryDefault
        delayedCaptureShortcut = .delayedCaptureDefault
        recordingShortcut = .recordingDefault
        scrollCaptureShortcut = .scrollCaptureDefault
        moleculePinShortcut = .moleculePinDefault
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
