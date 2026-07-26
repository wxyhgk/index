import Foundation

/// 内置后处理器。
///
/// 这个文件是「新增派生能力」的唯一登记处 —— 写一个 struct，再加一行注册。

/// 文字识别。结果进全文索引，于是「搜截图里的字」直接可用。
struct OCRProcessor: CapturePostProcessor {
    let id = "ocr"

    @MainActor var isEnabled: Bool { AppSettings.shared.runOCR }

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

    @MainActor var isEnabled: Bool { AppSettings.shared.autoClassify }

    func process(_ input: PostProcessInput, writer: ShotAttributeWriter) async {
        let category = ShotClassifier.classify(bundleID: input.appBundleID)
        await writer.write(shotID: input.shotID, key: AttributeKey.category, value: .text(category))
    }
}

/// Vision 场景标签。辅助信号，规则分类失手时至少还能按内容搜到。
struct VisionLabelsProcessor: CapturePostProcessor {
    let id = "vision-labels"

    @MainActor var isEnabled: Bool { AppSettings.shared.autoClassify }

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

extension CapturePipeline {
    /// 在这里登记。
    static func registerBuiltins(into pipeline: CapturePipeline) {
        pipeline.register(OCRProcessor())
        pipeline.register(BrowserURLProcessor())
        pipeline.register(CategoryProcessor())
        pipeline.register(VisionLabelsProcessor())
        pipeline.register(FeaturePrintProcessor())
    }
}
