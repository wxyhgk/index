import Foundation
import Vision
import CoreGraphics

/// 系统自带的图像特征指纹（Vision FeaturePrint）。零成本、无需下载模型。
///
/// 它只负责「像素 → 指纹」和「指纹 → 距离」两件事，
/// 指纹存到哪、拿来比什么由 `FeaturePrintProcessor` 和 `ShotStore` 决定。
struct FeaturePrint {

    /// 提取一张图的特征指纹，序列化成可落库的二进制。失败返回 nil。
    func extract(from image: CGImage) async -> Data? {
        await withCheckedContinuation { continuation in
            let request = VNGenerateImageFeaturePrintRequest()
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            do {
                try handler.perform([request])
                guard let observation = request.results?.first else {
                    continuation.resume(returning: nil)
                    return
                }
                let data = try NSKeyedArchiver.archivedData(
                    withRootObject: observation,
                    requiringSecureCoding: true
                )
                continuation.resume(returning: data)
            } catch {
                NSLog("[Index] 特征指纹提取失败: \(error)")
                continuation.resume(returning: nil)
            }
        }
    }

    /// 落库的二进制 → 指纹对象。数据损坏或版本不兼容时返回 nil，调用方跳过即可。
    static func observation(from data: Data) -> VNFeaturePrintObservation? {
        try? NSKeyedUnarchiver.unarchivedObject(
            ofClass: VNFeaturePrintObservation.self,
            from: data
        )
    }

    /// 两个指纹的距离。越小越相似；无法比较（指纹版本不同等）返回 nil。
    static func distance(
        _ lhs: VNFeaturePrintObservation,
        to rhs: VNFeaturePrintObservation
    ) -> Float? {
        var distance: Float = 0
        do {
            try lhs.computeDistance(&distance, to: rhs)
            return distance
        } catch {
            return nil
        }
    }
}
