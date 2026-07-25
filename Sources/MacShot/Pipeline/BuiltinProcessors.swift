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

extension CapturePipeline {
    /// 在这里登记。
    static func registerBuiltins(into pipeline: CapturePipeline) {
        pipeline.register(OCRProcessor())
        pipeline.register(BrowserURLProcessor())
    }
}
