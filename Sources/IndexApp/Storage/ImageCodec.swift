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
        if url.pathExtension.lowercased() == "svg" {
            return loadSVG(from: url)
        }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    static func load(from data: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, [
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary)
    }

    /// SVG 是矢量格式，ImageIO 不直接支持。用 NSImage 渲染成位图。
    /// 尺寸取 SVG 声明的 width/height；没有声明时默认 1024 宽、按宽高比算高。
    /// 注意：NSImage 的渲染必须在主线程（AppKit 约束），调用方需确保在主 actor。
    static func loadSVG(from url: URL) -> CGImage? {
        guard let image = NSImage(contentsOf: url) else { return nil }
        let size = svgRasterSize(for: image, url: url)
        let target = NSSize(width: size.width, height: size.height)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(target.width),
            pixelsHigh: Int(target.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        image.draw(in: NSRect(origin: .zero, size: target))
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage
    }

    /// SVG 栅格化尺寸：优先取 NSImage 声明的尺寸（= SVG 的 width/height 属性），
    /// 没有声明时默认 1024 宽、按宽高比算高。
    private static func svgRasterSize(for image: NSImage, url: URL) -> NSSize {
        let declared = image.size
        if declared.width > 1 && declared.height > 1 {
            return declared
        }
        // 没有声明尺寸：默认 1024 宽，按 NSImage 的宽高比（通常 1:1）算高。
        let ratio = declared.height / max(declared.width, 1)
        return NSSize(width: 1024, height: max(1, (1024 * ratio).rounded()))
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
