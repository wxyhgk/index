import CoreGraphics
import Foundation

struct SelectionAIImageSize: Equatable, Sendable {
    let width: Int
    let height: Int

    var longestEdge: Int { max(width, height) }
    var pixelCount: Int { width * height }
}

/// Provider 之前的纯像素准备。只负责等比降采样，不负责网络编码。
enum SelectionAIImagePreprocessor {
    static func targetSize(
        width: Int,
        height: Int,
        maxLongEdge: Int,
        maxPixelCount: Int
    ) -> SelectionAIImageSize? {
        guard width > 0, height > 0, maxLongEdge > 0, maxPixelCount > 0 else {
            return nil
        }
        let longEdgeScale = min(1, Double(maxLongEdge) / Double(max(width, height)))
        let pixelScale = min(
            1,
            sqrt(Double(maxPixelCount) / (Double(width) * Double(height)))
        )
        let scale = min(longEdgeScale, pixelScale)
        return SelectionAIImageSize(
            width: max(1, Int((Double(width) * scale).rounded(.down))),
            height: max(1, Int((Double(height) * scale).rounded(.down)))
        )
    }

    static func prepare(
        _ image: CGImage,
        maxLongEdge: Int,
        maxPixelCount: Int
    ) -> CGImage? {
        guard let target = targetSize(
            width: image.width,
            height: image.height,
            maxLongEdge: maxLongEdge,
            maxPixelCount: maxPixelCount
        ) else { return nil }
        guard target.width != image.width || target.height != image.height else { return image }

        guard let context = CGContext(
            data: nil,
            width: target.width,
            height: target.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(
            image,
            in: CGRect(x: 0, y: 0, width: target.width, height: target.height)
        )
        return context.makeImage()
    }
}
