import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AppKit

enum ImageCodec {

    static func pngData(from image: CGImage) -> Data? {
        encode(image, type: .png, properties: nil)
    }

    static func jpegData(from image: CGImage, quality: Double = 0.82) -> Data? {
        encode(image, type: .jpeg, properties: [
            kCGImageDestinationLossyCompressionQuality: quality
        ] as CFDictionary)
    }

    private static func encode(_ image: CGImage, type: UTType, properties: CFDictionary?) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dest, image, properties)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    static func load(from url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    static func load(from data: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, [
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary)
    }

    /// 等比缩放到最长边 maxDimension。
    static func resized(_ image: CGImage, maxDimension: Int) -> CGImage? {
        let w = image.width
        let h = image.height
        let longest = max(w, h)
        guard longest > maxDimension else { return image }

        let ratio = Double(maxDimension) / Double(longest)
        let newW = max(1, Int((Double(w) * ratio).rounded()))
        let newH = max(1, Int((Double(h) * ratio).rounded()))

        guard let ctx = CGContext(
            data: nil,
            width: newW,
            height: newH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: newW, height: newH))
        return ctx.makeImage()
    }

    static func nsImage(_ image: CGImage) -> NSImage {
        NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
}
