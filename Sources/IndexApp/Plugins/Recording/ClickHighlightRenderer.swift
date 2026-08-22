import AppKit
import CoreGraphics

/// 在步骤代表帧上画点击高亮圈，让人一眼看出「这一步点的是哪里」。
///
/// 坐标换算：点击位置是 **AppKit 全局坐标（左下原点，点）**，代表帧是
/// **像素坐标（左上原点）**。换算两步：
///   1. 全局 → 选区局部（点）：`x = click.x - region.minX`，
///      `y = region.maxY - click.y`（全局 y 向上，选区局部 y 向下）
///   2. 点 → 像素：乘以 `scale`
///
/// 纯函数，不碰 UI。点击落在选区外时圈画到帧外（自然不可见）—— 那是
/// 录制画面外的点击，本就不该在指南里高亮。
enum ClickHighlightRenderer {

    /// 高亮圈半径（点）。Retina 下自动按 scale 放大到像素。
    static let radiusPoints: CGFloat = 13
    /// 圆环线宽（点）。
    static let lineWidthPoints: CGFloat = 3.5

    /// 在 `image` 上画点击高亮圈，返回新图（原图不变）。
    static func highlight(
        image: CGImage,
        clickLocation: CGPoint,
        region: CGRect,
        scale: CGFloat
    ) -> CGImage {
        let width = image.width
        let height = image.height

        // 全局点坐标（左下原点）→ 帧像素坐标（左上原点）→ context 坐标（左下原点）。
        let xLocal = clickLocation.x - region.minX
        let yLocal = region.maxY - clickLocation.y
        let pixelX = xLocal * scale
        let pixelY = yLocal * scale
        let center = CGPoint(x: pixelX, y: CGFloat(height) - pixelY)

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        let radius = radiusPoints * scale
        let line = lineWidthPoints * scale
        let rect = CGRect(
            x: center.x - radius,
            y: center.y - radius,
            width: radius * 2,
            height: radius * 2
        )
        // 半透明填充 + 醒目圆环。
        context.setFillColor(NSColor.systemRed.withAlphaComponent(0.22).cgColor)
        context.fillEllipse(in: rect)
        context.setStrokeColor(NSColor.systemRed.withAlphaComponent(0.9).cgColor)
        context.setLineWidth(line)
        context.strokeEllipse(in: rect)

        return context.makeImage() ?? image
    }
}
