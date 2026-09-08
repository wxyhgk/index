import AppKit

/// 从来源 App 图标提取适合作为卡片标题栏的稳定强调色。
///
/// 不是简单求平均色：白色图标底板会把平均值冲成灰色。这里优先聚合饱和像素的
/// 主色相，再把亮度压到白字具备足够对比度的范围。低饱和图标则回退成中性深灰。
enum AppIconAccentExtractor {
    private static let sampleSide = 20
    private static let hueBinCount = 12

    static func color(from image: NSImage) -> NSColor? {
        guard let pixels = rgbaPixels(from: image) else { return nil }

        struct HueBucket {
            var weight = 0.0
            var red = 0.0
            var green = 0.0
            var blue = 0.0
        }

        var buckets = Array(repeating: HueBucket(), count: hueBinCount)
        var neutralBrightness = 0.0
        var neutralWeight = 0.0

        for offset in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Double(pixels[offset + 3]) / 255
            guard alpha > 0.12 else { continue }

            // CGContext 输出 premultiplied RGBA；采样前恢复真实 RGB。
            let red = min(1, Double(pixels[offset]) / 255 / alpha)
            let green = min(1, Double(pixels[offset + 1]) / 255 / alpha)
            let blue = min(1, Double(pixels[offset + 2]) / 255 / alpha)
            let hsv = hsv(red: red, green: green, blue: blue)

            // App 图标常见的白色圆角底板不是品牌主色。
            guard !(hsv.brightness > 0.92 && hsv.saturation < 0.14) else { continue }

            neutralBrightness += hsv.brightness * alpha
            neutralWeight += alpha

            guard hsv.saturation >= 0.16 else { continue }
            let index = min(hueBinCount - 1, Int(hsv.hue * Double(hueBinCount)))
            let weight = pow(hsv.saturation, 1.35)
                * (0.35 + hsv.brightness * 0.65)
                * alpha
            buckets[index].weight += weight
            buckets[index].red += red * weight
            buckets[index].green += green * weight
            buckets[index].blue += blue * weight
        }

        if let dominant = buckets.max(by: { $0.weight < $1.weight }), dominant.weight > 0.2 {
            let red = dominant.red / dominant.weight
            let green = dominant.green / dominant.weight
            let blue = dominant.blue / dominant.weight
            let source = hsv(red: red, green: green, blue: blue)
            let saturation = min(0.78, max(0.42, source.saturation * 0.92))
            let brightness = readableBrightness(hue: source.hue, saturation: saturation)
            return NSColor(
                calibratedHue: source.hue,
                saturation: saturation,
                brightness: brightness,
                alpha: 1
            )
        }

        guard neutralWeight > 0 else { return nil }
        let sourceBrightness = neutralBrightness / neutralWeight
        let gray = min(0.34, max(0.20, sourceBrightness * 0.45))
        return NSColor(calibratedWhite: gray, alpha: 1)
    }

    private static func rgbaPixels(from image: NSImage) -> [UInt8]? {
        var proposedRect = NSRect(origin: .zero, size: image.size)
        guard let source = image.cgImage(
            forProposedRect: &proposedRect,
            context: nil,
            hints: nil
        ) else { return nil }

        var pixels = [UInt8](repeating: 0, count: sampleSide * sampleSide * 4)
        guard let context = CGContext(
            data: &pixels,
            width: sampleSide,
            height: sampleSide,
            bitsPerComponent: 8,
            bytesPerRow: sampleSide * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                | CGBitmapInfo.byteOrder32Big.rawValue
        ) else { return nil }

        context.interpolationQuality = .medium
        context.draw(source, in: CGRect(x: 0, y: 0, width: sampleSide, height: sampleSide))
        return pixels
    }

    private static func hsv(
        red: Double,
        green: Double,
        blue: Double
    ) -> (hue: Double, saturation: Double, brightness: Double) {
        let maximum = max(red, green, blue)
        let minimum = min(red, green, blue)
        let delta = maximum - minimum
        let saturation = maximum == 0 ? 0 : delta / maximum

        guard delta > 0 else { return (0, saturation, maximum) }
        let rawHue: Double
        if maximum == red {
            rawHue = ((green - blue) / delta).truncatingRemainder(dividingBy: 6)
        } else if maximum == green {
            rawHue = (blue - red) / delta + 2
        } else {
            rawHue = (red - green) / delta + 4
        }
        let hue = (rawHue / 6 + 1).truncatingRemainder(dividingBy: 1)
        return (hue, saturation, maximum)
    }

    /// 黄、绿在相同 HSV 亮度下比蓝、紫更亮；逐步压低亮度，确保白字清晰。
    private static func readableBrightness(hue: Double, saturation: Double) -> Double {
        var brightness = 0.48
        while relativeLuminance(hue: hue, saturation: saturation, brightness: brightness) > 0.17,
              brightness > 0.28 {
            brightness -= 0.02
        }
        return brightness
    }

    private static func relativeLuminance(
        hue: Double,
        saturation: Double,
        brightness: Double
    ) -> Double {
        let color = NSColor(
            calibratedHue: hue,
            saturation: saturation,
            brightness: brightness,
            alpha: 1
        ).usingColorSpace(.sRGB) ?? .black

        func linear(_ component: CGFloat) -> Double {
            let value = Double(component)
            return value <= 0.04045
                ? value / 12.92
                : pow((value + 0.055) / 1.055, 2.4)
        }

        return 0.2126 * linear(color.redComponent)
            + 0.7152 * linear(color.greenComponent)
            + 0.0722 * linear(color.blueComponent)
    }
}

/// sourceApp → 标题栏颜色。颜色提取只会对每个来源 App 做一次，避免虚拟列表复用时
/// 重复解析图标；NSCache 在内存压力下会自动释放结果。
@MainActor
final class AppIconAccentColorProvider {
    static let shared = AppIconAccentColorProvider()

    private let cache = NSCache<NSString, NSColor>()
    private var inflight: [String: Task<NSColor?, Never>] = [:]

    private init() {
        cache.countLimit = 128
    }

    func cached(forName name: String?) -> NSColor? {
        guard let name, !name.isEmpty else { return nil }
        return cache.object(forKey: name as NSString)
    }

    func accent(forName name: String?) async -> NSColor? {
        guard let name, !name.isEmpty else { return nil }
        if let cached = cache.object(forKey: name as NSString) { return cached }

        let task: Task<NSColor?, Never>
        if let running = inflight[name] {
            task = running
        } else {
            task = Task { @MainActor in
                guard let icon = await AppIconProvider.shared.icon(forName: name) else { return nil }
                return AppIconAccentExtractor.color(from: icon)
            }
            inflight[name] = task
        }

        let color = await task.value
        inflight[name] = nil
        if let color { cache.setObject(color, forKey: name as NSString) }
        return color
    }
}
