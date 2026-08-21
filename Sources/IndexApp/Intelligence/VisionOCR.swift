import CoreGraphics

/// 系统自带的文字识别。零成本、无需下载模型。
///
/// 它只负责「认出字」，认完往哪儿放由 `OCRProcessor` 和 `ShotAttributeWriter` 决定。
/// 此前这里还兼管排队和写数据库，那让一个 OCR 引擎知道了 SQLite 的存在。
struct VisionOCR {

    func recognizeText(in image: CGImage) async -> String {
        text(from: await VisionTextRecognition().recognize(in: image))
    }

    func text(from lines: [VisionTextLine]) -> String {
        lines.map(\.text).joined(separator: "\n")
    }
}
