import Foundation

/// 内置后处理器。
///
/// 这个文件是「新增派生能力」的唯一登记处 —— 写一个 struct，再加一行注册。

/// 文字识别。结果进全文索引，于是「搜截图里的字」直接可用。
struct OCRProcessor: CapturePostProcessor {
    let id = "ocr"
    private let styleStore: any StyleStore

    init(styleStore: any StyleStore = AppSettings.shared) {
        self.styleStore = styleStore
    }

    @MainActor var isEnabled: Bool { styleStore.runOCR }

    func process(_ input: PostProcessInput, writer: ShotAttributeWriter) async {
        let text = await VisionOCR().recognizeText(in: input.image)
        guard !text.isEmpty else { return }
        await writer.write(shotID: input.shotID, key: AttributeKey.ocrText, value: .text(text))
    }
}

/// 浏览器当前标签页地址。失败或超时都只是没有地址，不影响任何其它环节。
struct BrowserURLProcessor: CapturePostProcessor {
    let id = "browser-url"

    func process(_ input: PostProcessInput, writer: ShotAttributeWriter) async {
        guard let bundleID = input.appBundleID,
              BrowserURLResolver.supports(bundleID),
              let url = await BrowserURLResolver.resolve(bundleID: bundleID)
        else { return }

        await writer.write(shotID: input.shotID, key: AttributeKey.sourceURL, value: .text(url))
    }
}

/// 规则分类：bundleID → 中文分类名。`.text` 落库自动进全文索引，
/// 于是搜「代码」「聊天」直接命中对应分类的截图。
struct CategoryProcessor: CapturePostProcessor {
    let id = "category"
    private let styleStore: any StyleStore

    init(styleStore: any StyleStore = AppSettings.shared) {
        self.styleStore = styleStore
    }

    @MainActor var isEnabled: Bool { styleStore.autoClassify }

    func process(_ input: PostProcessInput, writer: ShotAttributeWriter) async {
        let category = ShotClassifier.classify(bundleID: input.appBundleID)
        await writer.write(shotID: input.shotID, key: AttributeKey.category, value: .text(category.rawValue))
    }
}

/// Vision 场景标签。辅助信号，规则分类失手时至少还能按内容搜到。
struct VisionLabelsProcessor: CapturePostProcessor {
    let id = "vision-labels"
    private let styleStore: any StyleStore

    init(styleStore: any StyleStore = AppSettings.shared) {
        self.styleStore = styleStore
    }

    @MainActor var isEnabled: Bool { styleStore.autoClassify }

    func process(_ input: PostProcessInput, writer: ShotAttributeWriter) async {
        let labels = await VisionSceneLabels().labels(in: input.image)
        guard !labels.isEmpty else { return }
        await writer.write(
            shotID: input.shotID,
            key: AttributeKey.visionLabels,
            value: .text(labels.joined(separator: ","))
        )
    }
}

/// 图像特征指纹。二进制载荷进通用属性表的 payload 列，
/// searchableText 必须为 nil —— 二进制不进全文索引。「查找相似截图」靠它算距离。
struct FeaturePrintProcessor: CapturePostProcessor {
    let id = "feature-print"

    func process(_ input: PostProcessInput, writer: ShotAttributeWriter) async {
        guard let data = await FeaturePrint().extract(from: input.image) else { return }
        await writer.write(
            shotID: input.shotID,
            key: AttributeKey.featurePrint,
            value: .data(data, searchableText: nil)
        )
    }
}

/// MobileCLIP 图像向量。语义搜索（用自然语言搜截图）靠它算相似度。
/// 开关关闭或模型还没下载好时直接跳过 —— 模型就绪后由回填补齐。
struct CLIPEmbeddingProcessor: CapturePostProcessor {
    let id = "clip-embedding"
    private let styleStore: any StyleStore

    init(styleStore: any StyleStore = AppSettings.shared) {
        self.styleStore = styleStore
    }

    @MainActor var isEnabled: Bool {
        styleStore.semanticSearch && CLIPModelStore.shared.isReady
    }

    func process(_ input: PostProcessInput, writer: ShotAttributeWriter) async {
        guard let vector = await CLIPEncoder.shared.embedImage(input.image) else { return }
        await writer.write(
            shotID: input.shotID,
            key: AttributeKey.clipEmbedding,
            value: .data(CLIPEncoder.data(from: vector), searchableText: nil)
        )
    }
}

/// 敏感内容检测（邮箱 / 密钥 / 卡号 / 手机号 / 人脸）。
/// 命中区域以 JSON 落库，详情页据此显示警示条并支持一键打码。
/// searchableText 只放种类汇总 —— 搜「密钥」能找到含密钥的截图，
/// 但密钥本身绝不进索引。没检测到就什么都不写。
struct SensitiveContentProcessor: CapturePostProcessor {
    let id = "sensitive-content"
    private let styleStore: any StyleStore

    init(styleStore: any StyleStore = AppSettings.shared) {
        self.styleStore = styleStore
    }

    @MainActor var isEnabled: Bool { styleStore.detectSensitive }

    func process(_ input: PostProcessInput, writer: ShotAttributeWriter) async {
        let regions = await SensitiveContentDetector().detect(in: input.image)
        guard !regions.isEmpty, let json = try? JSONEncoder().encode(regions) else { return }

        var kinds: [String] = []
        for region in regions where !kinds.contains(region.kind) {
            kinds.append(region.kind)
        }
        await writer.write(
            shotID: input.shotID,
            key: AttributeKey.sensitiveRegions,
            value: .data(json, searchableText: kinds.joined(separator: ","))
        )
    }
}

extension CapturePipeline {
    /// 在这里登记。注入式：预览/测试可传 `FakeStyleStore`，默认走 `AppSettings.shared`。
    static func registerBuiltins(
        into pipeline: CapturePipeline,
        styleStore: any StyleStore = AppSettings.shared
    ) {
        pipeline.register(OCRProcessor(styleStore: styleStore))
        pipeline.register(BrowserURLProcessor())
        pipeline.register(CategoryProcessor(styleStore: styleStore))
        pipeline.register(VisionLabelsProcessor(styleStore: styleStore))
        pipeline.register(FeaturePrintProcessor())
        pipeline.register(CLIPEmbeddingProcessor(styleStore: styleStore))
        pipeline.register(SensitiveContentProcessor(styleStore: styleStore))
    }
}
