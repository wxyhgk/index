import Foundation
import Vision
import CoreGraphics

/// 分类/理解能力的第 1 层：系统自带 Vision，零成本、无需下载模型。
/// 识别出的文本回填到 shot.ocrText，由 FTS5 索引 —— 于是「搜截图里的字」直接可用。
///
/// 第 2 层（MobileCLIP embedding + 语义检索 / zero-shot 分类）后续接在这个协议下面，
/// 核心存储层不需要改动。
protocol ImageUnderstanding {
    func analyze(_ image: CGImage) async -> String
}

struct VisionOCR: ImageUnderstanding {

    func analyze(_ image: CGImage) async -> String {
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

enum ImageAnalysisQueue {

    private static let engine: ImageUnderstanding = VisionOCR()

    /// 后台跑 OCR，完成后回主线程写库。失败不影响任何东西。
    static func enqueue(image: CGImage, shotID: Int64) {
        Task.detached(priority: .utility) {
            let text = await engine.analyze(image)
            guard !text.isEmpty else { return }
            await MainActor.run {
                ShotStore.shared.updateOCR(shotID: shotID, text: text)
            }
        }
    }
}
