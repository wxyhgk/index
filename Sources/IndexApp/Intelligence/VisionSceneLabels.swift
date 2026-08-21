import Foundation
import Vision
import CoreGraphics

/// 系统自带的图像场景分类。零成本、无需下载模型。
///
/// 和 `VisionOCR` 一样只负责「认出标签」，落到哪儿由处理器决定。
struct VisionSceneLabels {

    /// 返回 confidence ≥ 0.3 的前 5 个 identifier，按置信度降序。
    func labels(in image: CGImage) async -> [String] {
        await withCheckedContinuation { continuation in
            let request = VNClassifyImageRequest { request, error in
                guard error == nil,
                      let results = request.results as? [VNClassificationObservation] else {
                    continuation.resume(returning: [])
                    return
                }
                let labels = results
                    .filter { $0.confidence >= 0.3 }
                    .sorted { $0.confidence > $1.confidence }
                    .prefix(5)
                    .map(\.identifier)
                continuation.resume(returning: Array(labels))
            }

            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            do {
                try handler.perform([request])
            } catch {
                NSLog("[Index] 场景分类失败: \(error)")
                continuation.resume(returning: [])
            }
        }
    }
}
