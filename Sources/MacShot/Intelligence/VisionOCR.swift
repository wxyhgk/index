import Foundation
import Vision
import CoreGraphics

/// 系统自带的文字识别。零成本、无需下载模型。
///
/// 它只负责「认出字」，认完往哪儿放由 `OCRProcessor` 和 `ShotAttributeWriter` 决定。
/// 此前这里还兼管排队和写数据库，那让一个 OCR 引擎知道了 SQLite 的存在。
struct VisionOCR {

    func recognizeText(in image: CGImage) async -> String {
        await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                guard error == nil,
                      let results = request.results as? [VNRecognizedTextObservation] else {
                    continuation.resume(returning: "")
                    return
                }
                let text = results
                    .compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: "\n")
                continuation.resume(returning: text)
            }

            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = ["zh-Hans", "en-US"]

            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            do {
                try handler.perform([request])
            } catch {
                NSLog("[MacShot] OCR 失败: \(error)")
                continuation.resume(returning: "")
            }
        }
    }
}
