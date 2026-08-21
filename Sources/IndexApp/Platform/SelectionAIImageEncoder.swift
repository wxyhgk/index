import CoreGraphics
import Foundation

struct SelectionAIEncodedImage: Sendable {
    let data: Data
    let mimeType: String
    let pixelSize: SelectionAIImageSize
}

enum SelectionAIImageEncoderError: Error {
    case preparationFailed
    case encodingFailed
    case remainsTooLarge(Int)
}

/// 将局部选区压到任务预算内。科学内容统一保留 PNG；若 PNG 仍过大，
/// 会有限次继续等比降采样，但不低于任务的可读性下限。
enum SelectionAIImageEncoder {
    static func encode(
        _ source: CGImage,
        policy: SelectionAIRequestPolicy
    ) throws -> SelectionAIEncodedImage {
        guard var image = SelectionAIImagePreprocessor.prepare(
            source,
            maxLongEdge: policy.maxLongEdge,
            maxPixelCount: policy.maxPixelCount
        ) else { throw SelectionAIImageEncoderError.preparationFailed }

        var data: Data
        guard let initial = ImageCodec.pngData(from: image) else {
            throw SelectionAIImageEncoderError.encodingFailed
        }
        data = initial

        for _ in 0..<3 where data.count > policy.maxEncodedBytes {
            let currentLongEdge = max(image.width, image.height)
            guard currentLongEdge > policy.minimumLongEdge else { break }
            let estimatedScale = sqrt(
                Double(policy.maxEncodedBytes) / Double(data.count)
            ) * 0.94
            let nextLongEdge = max(
                policy.minimumLongEdge,
                min(currentLongEdge - 1, Int(Double(currentLongEdge) * estimatedScale))
            )
            guard let resized = SelectionAIImagePreprocessor.prepare(
                image,
                maxLongEdge: nextLongEdge,
                maxPixelCount: nextLongEdge * nextLongEdge
            ), resized.width != image.width || resized.height != image.height,
                  let encoded = ImageCodec.pngData(from: resized)
            else { break }
            image = resized
            data = encoded
        }

        guard data.count <= policy.maxEncodedBytes else {
            throw SelectionAIImageEncoderError.remainsTooLarge(data.count)
        }
        return SelectionAIEncodedImage(
            data: data,
            mimeType: "image/png",
            pixelSize: SelectionAIImageSize(width: image.width, height: image.height)
        )
    }
}
