import AppKit
import CoreText

/// 测量：拖出矩形或线段，旁边标注**图像像素**尺寸。
///
/// 数值在生成时就烤进 `layer.text`（按画布→像素倍率换算）——
/// 覆盖层画布是点、导出是像素，只有生成时算好才能保证预览和成品显示同一个数。
struct DimensionTool: AnnotationToolDescriptor {
    let tool = AnnotationTool.dimension
    let axes: [ToolStyleAxis] = [.color, .width]
    let defaultStyle = ToolStyle()
    let shortcut: (keyCode: UInt16, label: String)? = (KeyCode.m, "M")

    func makeLayer(_ context: ToolLayerContext) -> Layer {
        var layer = baseLayer(context)
        Self.prepare(&layer, pixelScale: context.pixelScale)
        return layer
    }

    func resize(
        _ original: Layer, handle: ResizeHandle, delta: CGPoint, pixelScale: Double
    ) -> Layer {
        var layer = original
        layer.rect = LRect(handle.apply(delta: delta, to: original.rect.cg))
        Self.prepare(&layer, pixelScale: pixelScale)
        return layer
    }

    /// 允许单维为 0（吸附形态），所以只看长边。
    func meetsMinimumSize(_ layer: Layer) -> Bool {
        max(abs(layer.rect.w), abs(layer.rect.h)) >= ToolGeometry.minimumSide
    }

    /// 整形。拖拽过程中每帧都会经过这里（`pendingLayer` 每帧重建图层）。
    ///   · 近似横/竖的拖拽（薄轴不足 8 像素）吸附成单维 —— 薄轴收拢为 0，
    ///     绘制据此退化为双箭头线段，只标长度
    ///   · 数值按 `pixelScale` 换算成图像像素后烤进 `text`
    static func prepare(_ layer: inout Layer, pixelScale: Double) {
        var rect = layer.rect.cg.standardized
        if min(rect.width, rect.height) * pixelScale < 8 {
            rect = rect.width >= rect.height
                ? CGRect(x: rect.minX, y: rect.midY, width: rect.width, height: 0)
                : CGRect(x: rect.midX, y: rect.minY, width: 0, height: rect.height)
        }
        layer.rect = LRect(rect)

        let w = Int((rect.width * pixelScale).rounded())
        let h = Int((rect.height * pixelScale).rounded())
        if rect.height == 0 {
            layer.text = "\(w) px"
        } else if rect.width == 0 {
            layer.text = "\(h) px"
        } else {
            layer.text = "\(w) × \(h) px"
        }
    }

    // MARK: - 绘制

    /// 两种形态，由 `prepare` 在生成时定下：
    ///   · 矩形：细边框 + 四边中点向外的短刻度线，中央挂 `W × H px` 胶囊标签
    ///   · 单维（薄轴已被吸附成 0）：双箭头线段，标签只有长度，横线标签在上、竖线在右
    /// `text` 为空则退回矩形自身尺寸 —— 图像像素空间里两者本就相等。
    func draw(_ layer: Layer, in ctx: CGContext) {
        let rect = layer.rect.cg.standardized
        guard rect.width >= 1 || rect.height >= 1 else { return }

        // 「细」相对当前空间：lineWidth 随投影缩放，边框在屏幕上始终约 1pt。
        let hairline = max(1, layer.lineWidth / 4)
        let singleAxis = min(rect.width, rect.height) < 1

        ctx.saveGState()
        ctx.setStrokeColor(layer.color.cg)
        ctx.setLineWidth(hairline)

        if singleAxis {
            let horizontal = rect.width >= rect.height
            Self.drawDoubleArrow(
                from: horizontal
                    ? CGPoint(x: rect.minX, y: rect.midY)
                    : CGPoint(x: rect.midX, y: rect.minY),
                to: horizontal
                    ? CGPoint(x: rect.maxX, y: rect.midY)
                    : CGPoint(x: rect.midX, y: rect.maxY),
                lineWidth: hairline,
                in: ctx
            )
        } else {
            ctx.stroke(rect)
            let tick = 4 * hairline
            for (a, b) in [
                (CGPoint(x: rect.midX, y: rect.minY), CGPoint(x: rect.midX, y: rect.minY - tick)),
                (CGPoint(x: rect.midX, y: rect.maxY), CGPoint(x: rect.midX, y: rect.maxY + tick)),
                (CGPoint(x: rect.minX, y: rect.midY), CGPoint(x: rect.minX - tick, y: rect.midY)),
                (CGPoint(x: rect.maxX, y: rect.midY), CGPoint(x: rect.maxX + tick, y: rect.midY))
            ] {
                ctx.move(to: a)
                ctx.addLine(to: b)
            }
            ctx.strokePath()
        }
        ctx.restoreGState()

        var text = layer.text
        if text.isEmpty {
            let w = Int(rect.width.rounded())
            let h = Int(rect.height.rounded())
            text = singleAxis ? "\(max(w, h)) px" : "\(w) × \(h) px"
        }
        Self.drawLabel(
            text, layer: layer, rect: rect, singleAxis: singleAxis, gap: 3 * hairline, in: ctx
        )
    }

    /// 双箭头线段：主干 + 两端向内张开的 V 形箭头。
    private static func drawDoubleArrow(
        from a: CGPoint, to b: CGPoint, lineWidth: CGFloat, in ctx: CGContext
    ) {
        let length = hypot(b.x - a.x, b.y - a.y)
        guard length > 1 else { return }
        let angle = atan2(b.y - a.y, b.x - a.x)
        let head = min(length / 3, max(5, lineWidth * 5))
        let spread = CGFloat.pi / 6

        ctx.saveGState()
        ctx.setLineCap(.round)
        ctx.move(to: a)
        ctx.addLine(to: b)
        // back 指向线段内侧：箭头的两翼从端点往里张开。
        for (tip, back) in [(a, angle), (b, angle + .pi)] {
            for side in [-spread, spread] {
                ctx.move(to: tip)
                ctx.addLine(to: CGPoint(
                    x: tip.x + cos(back + side) * head,
                    y: tip.y + sin(back + side) * head
                ))
            }
        }
        ctx.strokePath()
        ctx.restoreGState()
    }

    /// 尺寸标签：白字黑底胶囊。矩形模式挂在中央；横线在线上方、竖线在线右侧。
    private static func drawLabel(
        _ text: String,
        layer: Layer,
        rect: CGRect,
        singleAxis: Bool,
        gap: CGFloat,
        in ctx: CGContext
    ) {
        let font = NSFont.monospacedDigitSystemFont(
            ofSize: layer.fontSize * 0.6, weight: .semibold
        )
        let attributed = NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: NSColor.white
        ])
        let line = CTLineCreateWithAttributedString(attributed)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        let textWidth = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
        let padX = font.pointSize * 0.5
        let padY = font.pointSize * 0.25
        let size = CGSize(
            width: textWidth + padX * 2,
            height: ascent + descent + padY * 2
        )

        let center: CGPoint
        if !singleAxis {
            center = CGPoint(x: rect.midX, y: rect.midY)
        } else if rect.width >= rect.height {
            center = CGPoint(x: rect.midX, y: rect.midY - size.height / 2 - gap)
        } else {
            center = CGPoint(x: rect.midX + size.width / 2 + gap, y: rect.midY)
        }
        let box = CGRect(
            x: center.x - size.width / 2,
            y: center.y - size.height / 2,
            width: size.width,
            height: size.height
        )

        ctx.saveGState()
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.72))
        ctx.addPath(CGPath(
            roundedRect: box,
            cornerWidth: size.height / 2,
            cornerHeight: size.height / 2,
            transform: nil
        ))
        ctx.fillPath()
        // 上下文当前是翻转的（左上原点），文字需要再翻一次才不会上下颠倒。
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        ctx.textPosition = CGPoint(
            x: box.minX + padX,
            y: center.y + (ascent - descent) / 2
        )
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }
}
