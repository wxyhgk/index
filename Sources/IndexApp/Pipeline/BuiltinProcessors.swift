import Foundation

/// 内置后处理器。
///
/// 这个文件是「新增派生能力」的唯一登记处 —— 写一个 struct，再加一行注册。

/// 文字识别。结果进全文索引，于是「搜截图里的字」直接可用。
struct OCRProcessor: CapturePostProcessor {
    let id = "ocr"
    private let intelligence: any IntelligencePreferences

    init(intelligence: any IntelligencePreferences) {
        self.intelligence = intelligence
    }

    @MainActor var isEnabled: Bool { intelligence.runOCR }

    func process(_ input: PostProcessInput, writer: ShotAttributeWriter) async {
        let text = VisionOCR().text(from: await input.analysis.recognizedText())
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
    private let intelligence: any IntelligencePreferences

    init(intelligence: any IntelligencePreferences) {
        self.intelligence = intelligence
    }

    @MainActor var isEnabled: Bool { intelligence.autoClassify }

    func process(_ input: PostProcessInput, writer: ShotAttributeWriter) async {
        let category = ShotClassifier.classify(bundleID: input.appBundleID)
        await writer.write(shotID: input.shotID, key: AttributeKey.category, value: .text(category.rawValue))
    }
}

/// Vision 场景标签。辅助信号，规则分类失手时至少还能按内容搜到。
struct VisionLabelsProcessor: CapturePostProcessor {
    let id = "vision-labels"
    private let intelligence: any IntelligencePreferences

    init(intelligence: any IntelligencePreferences) {
        self.intelligence = intelligence
    }

    @MainActor var isEnabled: Bool { intelligence.autoClassify }

    func process(_ input: PostProcessInput, writer: ShotAttributeWriter) async {
        let labels = await VisionSceneLabels().labels(in: input.image)
        await writer.write(
            shotID: input.shotID,
            key: AttributeKey.visionLabels,
            // 空串也是“已经分析且没有标签”。不落这一行会让回填器每次启动重跑。
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
    private let intelligence: any IntelligencePreferences

    init(intelligence: any IntelligencePreferences) {
        self.intelligence = intelligence
    }

    @MainActor var isEnabled: Bool {
        intelligence.semanticSearch && CLIPModelStore.shared.isReady
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
    private let intelligence: any IntelligencePreferences

    init(intelligence: any IntelligencePreferences) {
        self.intelligence = intelligence
    }

    @MainActor var isEnabled: Bool { intelligence.detectSensitive }

    func process(_ input: PostProcessInput, writer: ShotAttributeWriter) async {
        let recognizedText = await input.analysis.recognizedText()
        let regions = await SensitiveContentDetector().detect(
            in: input.image,
            recognizedText: recognizedText
        )
        guard let value = Self.attributeValue(for: regions) else { return }
        await writer.write(
            shotID: input.shotID,
            key: AttributeKey.sensitiveRegions,
            value: value
        )
    }

    /// 空数组也编码落库，作为“已检测、没有命中”的完成哨兵。
    static func attributeValue(for regions: [SensitiveRegion]) -> AttributeValue? {
        guard let json = try? JSONEncoder().encode(regions) else { return nil }
        var kinds: [String] = []
        for region in regions where !kinds.contains(region.kind) {
            kinds.append(region.kind)
        }
        return .data(
            json,
            searchableText: kinds.isEmpty ? nil : kinds.joined(separator: ",")
        )
    }
}

/// 截图后自动生成 Markdown 附加数据（不改变 contentKind，卡片仍显示图片）。
/// 用户后续可切换为 Markdown 视图或导出 .md 文件。
struct MarkdownGeneratorProcessor: CapturePostProcessor {
    let id = "markdown-generator"

    func process(_ input: PostProcessInput, writer: ShotAttributeWriter) async {
        let source = MarkdownGenerator.generate(
            title: input.metadata.title,
            sha256: input.metadata.sha256,
            appName: input.metadata.appName,
            capturedAt: input.metadata.capturedAt,
            pixelWidth: input.metadata.pixelWidth,
            pixelHeight: input.metadata.pixelHeight,
            ocrText: input.metadata.ocrText
        )
        await writer.saveContent(shotID: input.shotID, kind: .markdown, payload: .markdown(source))
    }
}

extension CapturePipeline {
    /// 在这里登记。注入式：装配根（AppDelegate）传全量设置，预览/测试传 `FakeStyleStore`。
    static func registerBuiltins(
        into pipeline: CapturePipeline,
        styleStore: any IntelligencePreferences
    ) {
        pipeline.register(OCRProcessor(intelligence: styleStore))
        pipeline.register(BrowserURLProcessor())
        pipeline.register(CategoryProcessor(intelligence: styleStore))
        pipeline.register(VisionLabelsProcessor(intelligence: styleStore))
        pipeline.register(FeaturePrintProcessor())
        pipeline.register(CLIPEmbeddingProcessor(intelligence: styleStore))
        pipeline.register(SensitiveContentProcessor(intelligence: styleStore))
        pipeline.register(MarkdownGeneratorProcessor())
    }
}
