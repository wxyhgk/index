import AppKit
import CoreGraphics
import CoreImage
import CoreText

/// 把「原图 + 图层数组」渲染成一张图。
/// 原图始终只读；这里产出的是临时结果，只在预览和导出时使用。
enum LayerRenderer {

    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    static func render(base: CGImage, layers: [Layer]) -> CGImage {
        guard !layers.isEmpty else { return base }

        // 1. 先把马赛克作用到底图上（它是像素级操作，必须在绘制矢量图层之前）。
        let pixelated = layers.filter { $0.kind == .pixelate }
        var working = base
        if !pixelated.isEmpty {
            working = applyPixelate(to: base, regions: pixelated.map(\.rect.cg)) ?? base
        }

        let width = working.width
        let height = working.height

        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return base }

        ctx.draw(working, in: CGRect(x: 0, y: 0, width: width, height: height))

        // 翻转成左上原点，与图层存储的坐标系一致。
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)

        for layer in layers where layer.kind != .pixelate && layer.kind != .crop {
            draw(layer, in: ctx)
        }

        guard var result = ctx.makeImage() else { return base }

        // 2. 裁剪永远最后应用，且只影响输出，不影响存储。
        if let crop = layers.last(where: { $0.kind == .crop }) {
            let r = crop.rect.cg.integral.intersection(
                CGRect(x: 0, y: 0, width: width, height: height)
            )
            if r.width >= 1, r.height >= 1, let cropped = result.cropping(to: r) {
                result = cropped
            }
        }

        return result
    }

    // MARK: - 单个图层

    private static func draw(_ layer: Layer, in ctx: CGContext) {
        let rect = layer.rect.cg

        switch layer.kind {
        case .rect:
            ctx.setStrokeColor(layer.color.cg)
            ctx.setLineWidth(layer.lineWidth)
            ctx.stroke(rect)

        case .ellipse:
            ctx.setStrokeColor(layer.color.cg)
            ctx.setLineWidth(layer.lineWidth)
            ctx.strokeEllipse(in: rect)

        case .highlight:
            ctx.saveGState()
            ctx.setBlendMode(.multiply)
            ctx.setFillColor(layer.color.cg)
            ctx.fill(rect)
            ctx.restoreGState()

        case .line:
            ctx.setStrokeColor(layer.color.cg)
            ctx.setLineWidth(layer.lineWidth)
            ctx.setLineCap(.round)
            ctx.move(to: layer.rect.start)
            ctx.addLine(to: layer.rect.end)
            ctx.strokePath()

        case .arrow:
            drawArrow(from: layer.rect.start, to: layer.rect.end, layer: layer, in: ctx)

        case .text:
            drawText(layer, in: ctx)

        case .pixelate, .crop:
            break   // 已在别处处理
        }
    }

    private static func drawArrow(from a: CGPoint, to b: CGPoint, layer: Layer, in ctx: CGContext) {
        let width: CGFloat = CGFloat(layer.lineWidth)
        let headLength: CGFloat = max(12, width * 4)
        let angle: CGFloat = atan2(b.y - a.y, b.x - a.x)
        let distance: CGFloat = hypot(b.x - a.x, b.y - a.y)
        guard distance > 1 else { return }

        // 主干缩短一个箭头长度，避免线头戳出箭尖。
        let shaftEnd = CGPoint(
            x: b.x - cos(angle) * headLength * 0.75,
            y: b.y - sin(angle) * headLength * 0.75
        )

        ctx.setStrokeColor(layer.color.cg)
        ctx.setFillColor(layer.color.cg)
        ctx.setLineWidth(width)
        ctx.setLineCap(.round)
        ctx.move(to: a)
        ctx.addLine(to: shaftEnd)
        ctx.strokePath()

        let spread = CGFloat.pi / 7
        ctx.move(to: b)
        ctx.addLine(to: CGPoint(
            x: b.x - cos(angle - spread) * headLength,
            y: b.y - sin(angle - spread) * headLength
        ))
        ctx.addLine(to: CGPoint(
            x: b.x - cos(angle + spread) * headLength,
            y: b.y - sin(angle + spread) * headLength
        ))
        ctx.closePath()
        ctx.fillPath()
    }

    private static func drawText(_ layer: Layer, in ctx: CGContext) {
        guard !layer.text.isEmpty else { return }

        let font = NSFont.systemFont(ofSize: layer.fontSize, weight: .semibold)
        let attributed = NSAttributedString(string: layer.text, attributes: [
            .font: font,
            .foregroundColor: NSColor(cgColor: layer.color.cg) ?? .systemRed
        ])
        let line = CTLineCreateWithAttributedString(attributed)

        ctx.saveGState()
        // 上下文当前是翻转的（左上原点），文字需要再翻一次才不会上下颠倒。
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        var ascent: CGFloat = 0
        CTLineGetTypographicBounds(line, &ascent, nil, nil)
        ctx.textPosition = CGPoint(x: layer.rect.x, y: layer.rect.y + ascent)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    // MARK: - 马赛克

    private static func applyPixelate(to image: CGImage, regions: [CGRect]) -> CGImage? {
        let extentHeight = CGFloat(image.height)
        var current = CIImage(cgImage: image)

        for region in regions {
            let r = region.integral
            guard r.width >= 2, r.height >= 2 else { continue }

            // CIImage 是左下原点，图层坐标是左上原点，这里翻过来。
            let ciRect = CGRect(
                x: r.origin.x,
                y: extentHeight - r.maxY,
                width: r.width,
                height: r.height
            )

            let scale = max(6, min(r.width, r.height) / 12)
            guard let filter = CIFilter(name: "CIPixellate") else { continue }
            filter.setValue(current, forKey: kCIInputImageKey)
            filter.setValue(scale, forKey: kCIInputScaleKey)
            filter.setValue(CIVector(x: ciRect.midX, y: ciRect.midY), forKey: kCIInputCenterKey)
            guard let output = filter.outputImage else { continue }

            // 只把马赛克结果贴回选定区域。
            current = output.cropped(to: ciRect).composited(over: current)
        }

        return ciContext.createCGImage(
            current,
            from: CGRect(x: 0, y: 0, width: image.width, height: image.height)
        )
    }
}
