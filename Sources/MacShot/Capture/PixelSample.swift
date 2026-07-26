import AppKit
import CoreGraphics

/// 光标处的一小块像素。放大镜和取色器共用。
struct PixelSample {
    /// 以光标为中心的一小块原始像素，等待被放大绘制。
    let patch: CGImage
    /// 正中心那一个像素的颜色。
    let color: LColor
    /// 光标所在的图像像素坐标（左上原点），给「坐标」读数用。
    let pixelPoint: CGPoint
    /// patch 的边长（像素数），奇数，保证有正中心。
    let patchSize: Int
}

extension LColor {
    var hexString: String {
        String(
            format: "#%02X%02X%02X",
            Int((r * 255).rounded()),
            Int((g * 255).rounded()),
            Int((b * 255).rounded())
        )
    }

    var nsColor: NSColor {
        NSColor(srgbRed: r, green: g, blue: b, alpha: a)
    }
}

extension DisplaySnapshot {

    /// 以某个全局点为中心采样。冻结架构下这是纯内存操作 ——
    /// 不用二次截屏，也就没有「取到的颜色是另一帧的」这种问题。
    func sample(aroundGlobal point: CGPoint, radius: Int = 10) -> PixelSample? {
        let px = ((point.x - frame.minX) * scale).rounded(.down)
        let py = ((frame.maxY - point.y) * scale).rounded(.down)

        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        guard bounds.contains(CGPoint(x: px, y: py)) else { return nil }

        let size = radius * 2 + 1
        let patchRect = CGRect(
            x: px - CGFloat(radius),
            y: py - CGFloat(radius),
            width: CGFloat(size),
            height: CGFloat(size)
        )

        // 靠边时把取样框推回图内，保证 patch 始终是完整的正方形，
        // 否则放大镜会在屏幕边缘变形。
        let clamped = CGRect(
            x: min(max(0, patchRect.minX), CGFloat(image.width - size)),
            y: min(max(0, patchRect.minY), CGFloat(image.height - size)),
            width: CGFloat(size),
            height: CGFloat(size)
        )
        guard let patch = image.cropping(to: clamped) else { return nil }
        guard let color = pixelColor(atX: Int(px), y: Int(py)) else { return nil }

        return PixelSample(
            patch: patch,
            color: color,
            pixelPoint: CGPoint(x: px, y: py),
            patchSize: size
        )
    }

    /// 读单个像素。
    ///
    /// 先裁成 1×1 再画进已知格式的位图，而不是直接解析源图的字节 ——
    /// ScreenCaptureKit 给的位图可能是 BGRA、也可能带 alpha skip，猜错了颜色会静默偏。
    private func pixelColor(atX x: Int, y: Int) -> LColor? {
        guard let dot = image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)) else {
            return nil
        }

        var pixel = [UInt8](repeating: 0, count: 4)
        guard let ctx = CGContext(
            data: &pixel,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        ctx.draw(dot, in: CGRect(x: 0, y: 0, width: 1, height: 1))

        return LColor(
            r: Double(pixel[0]) / 255,
            g: Double(pixel[1]) / 255,
            b: Double(pixel[2]) / 255,
            a: 1
        )
    }
}
