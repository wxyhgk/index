import AVFoundation
import ImageIO
import UniformTypeIdentifiers

enum GIFExportError: Error, LocalizedError {
    case tooLong
    case noVideo
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .tooLong:
            return "录制过长，GIF 仅支持 \(Int(GIFExporter.maxDuration)) 秒内"
        case .noVideo:
            return "视频里没有可用画面"
        case .writeFailed:
            return "GIF 写入失败"
        }
    }
}

/// mp4 → gif。AVAssetImageGenerator 按 10fps 抽帧（长边缩到 ≤800px），
/// CGImageDestination 写 gif：帧延迟 0.1s，无限循环。
///
/// 纯函数式，不碰 UI —— 调用方决定何时转、转完做什么。
enum GIFExporter {

    static let maxDuration: TimeInterval = 30
    static let framesPerSecond: Double = 10
    static let maxDimension: CGFloat = 800

    /// 在视频旁边生成同名 `.gif`，返回其路径。时长超过 `maxDuration` 直接拒绝。
    static func export(videoURL: URL) async throws -> URL {
        let asset = AVURLAsset(url: videoURL)
        let duration = try await asset.load(.duration).seconds
        guard duration > 0 else { throw GIFExportError.noVideo }
        guard duration <= maxDuration else { throw GIFExportError.tooLong }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        // 传入的是包围盒，生成器自己保持宽高比 —— 效果就是长边 ≤ maxDimension。
        generator.maximumSize = CGSize(width: maxDimension, height: maxDimension)
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 30)
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 30)

        let frameDelay = 1 / framesPerSecond
        let frameCount = max(1, Int(duration * framesPerSecond))
        let gifURL = videoURL.deletingPathExtension().appendingPathExtension("gif")

        guard let destination = CGImageDestinationCreateWithURL(
            gifURL as CFURL,
            UTType.gif.identifier as CFString,
            frameCount,
            nil
        ) else { throw GIFExportError.writeFailed }

        // 文件级属性：循环次数 0 = 无限循环。
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
        ] as CFDictionary)

        let frameProperties = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: frameDelay,
                kCGImagePropertyGIFUnclampedDelayTime: frameDelay
            ]
        ] as CFDictionary

        // 目的地按 frameCount 张创建，帧数必须凑齐 ——
        // 个别时间点取帧失败（如恰好越过末帧）就重复上一帧补位。
        var lastImage: CGImage?
        for index in 0..<frameCount {
            let time = CMTime(seconds: Double(index) * frameDelay, preferredTimescale: 600)
            if let image = try? await generator.image(at: time).image {
                lastImage = image
            }
            guard let image = lastImage else { throw GIFExportError.noVideo }
            CGImageDestinationAddImage(destination, image, frameProperties)
        }

        guard CGImageDestinationFinalize(destination) else { throw GIFExportError.writeFailed }
        return gifURL
    }
}
