import AppKit
import CoreGraphics
import CoreImage
import CoreText

/// 把「原图 + 图层数组」渲染成一张图。
/// 原图始终只读；这里产出的是临时结果，只在预览和导出时使用。
enum LayerRenderer {

    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    /// 只接受图像像素空间的图层 —— 画布空间的图层必须先经 `Layers.projected` 换算。
    static func render(base: CGImage, layers: Layers<ImageSpace>) -> CGImage {
        let layers = layers.elements
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

        drawVectors(layers, in: ctx)

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

    /// 在**已经是左上原点、Y 向下**的上下文里绘制矢量图层。
    ///
    /// 离屏导出和截图覆盖层的实时预览共用这一份代码 —— 所见即所得靠的就是这个，
    /// 而不是两套各自维护的绘制逻辑。
    static func drawVectors(_ layers: [Layer], in ctx: CGContext) {
        // 聚光灯画在其余矢量层**之下**：所有聚光灯层合并成一次遮罩绘制，
        // 多个聚光灯 = 多个亮区，标注本身不被压暗。
        let spotlights = layers.filter { $0.kind == .spotlight }
        if !spotlights.isEmpty {
            drawSpotlightMask(spotlights, in: ctx)
        }
        for layer in layers
        where layer.kind != .pixelate && layer.kind != .crop && layer.kind != .spotlight {
            draw(layer, in: ctx)
        }
    }

    /// 把整张小图马赛克化。覆盖层用它给每个马赛克图层预先算好贴片。
    static func pixelated(_ image: CGImage) -> CGImage? {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let blockSize = max(6, min(width, height) / 12)

        guard let filter = CIFilter(name: "CIPixellate") else { return nil }
        filter.setValue(CIImage(cgImage: image), forKey: kCIInputImageKey)
        filter.setValue(blockSize, forKey: kCIInputScaleKey)
        filter.setValue(CIVector(x: width / 2, y: height / 2), forKey: kCIInputCenterKey)

        guard let output = filter.outputImage else { return nil }
        return ciContext.createCGImage(
            output,
            from: CGRect(x: 0, y: 0, width: width, height: height)
        )
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

        case .counter:
            drawCounter(layer, in: ctx)

        case .pixelate, .crop, .spotlight:
            break   // 已在别处处理
        }
    }

    /// 聚光灯遮罩：整个可绘制区域铺一层半透明黑，再把每个聚光灯矩形挖亮。
    /// 用透明图层 + destinationOut 挖洞，而不是 even-odd —— 两个聚光灯重叠时
    /// even-odd 会把交集重新填黑，挖洞则不管怎么叠都是亮的。
    private static func drawSpotlightMask(_ spotlights: [Layer], in ctx: CGContext) {
        // 上下文此刻已是图层坐标系；裁剪盒就是「当前可见的画布范围」：
        // 离屏导出时是整张图，覆盖层预览时是选区。
        let canvas = ctx.boundingBoxOfClipPath
        guard !canvas.isEmpty else { return }

        ctx.saveGState()
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.55))
        ctx.fill(canvas)
        ctx.setBlendMode(.destinationOut)
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        for layer in spotlights {
            let r = layer.rect.cg
            if r.width >= 1, r.height >= 1 {
                ctx.fill(r)
            }
        }
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    /// 序号徽章：实心圆 + 白色粗体数字居中。`rect` 是圆的外接矩形（左上原点），
    /// 字号从圆径推导，两位数也放得下。
    private static func drawCounter(_ layer: Layer, in ctx: CGContext) {
        let rect = layer.rect.cg
        guard rect.width >= 1, rect.height >= 1 else { return }

        ctx.setFillColor(layer.color.cg)
        ctx.fillEllipse(in: rect)

        guard !layer.text.isEmpty else { return }
        let font = NSFont.systemFont(ofSize: rect.height * 0.52, weight: .bold)
        let attributed = NSAttributedString(string: layer.text, attributes: [
            .font: font,
            .foregroundColor: NSColor.white
        ])
        let line = CTLineCreateWithAttributedString(attributed)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))

        ctx.saveGState()
        // 上下文当前是翻转的（左上原点），文字需要再翻一次才不会上下颠倒。
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        ctx.textPosition = CGPoint(
            x: rect.midX - width / 2,
            y: rect.midY + (ascent - descent) / 2
        )
        CTLineDraw(line, ctx)
        ctx.restoreGState()
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
