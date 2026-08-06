import AppKit
import CoreText

/// 序号：点一下落一个带编号的圆徽章，编号自动递增。
struct CounterTool: AnnotationToolDescriptor {
    let tool = AnnotationTool.counter
    let axes: [ToolStyleAxis] = [.color, .fontSize]
    let defaultStyle = ToolStyle()
    let input = ToolInput.click
    let shortcut: (keyCode: UInt16, label: String)? = (KeyCode.n, "N")

    /// 点击处是圆心，`rect` 存外接正方形；编号扫现有序号层取最大值 +1。
    /// 刻意不在删除时重排 —— 删掉中间某个序号后，后续编号保持不变。
    func makeLayer(_ context: ToolLayerContext) -> Layer {
        var layer = baseLayer(context)
        let diameter = max(28 * context.strokeScale, layer.fontSize * 1.4)
        layer.rect = LRect(CGRect(
            x: context.from.x - diameter / 2,
            y: context.from.y - diameter / 2,
            width: diameter,
            height: diameter
        ))
        let next = (context.existing
            .filter { $0.kind == .counter }
            .compactMap { Int($0.text) }
            .max() ?? 0) + 1
        layer.text = String(next)
        return layer
    }

    /// 徽章是圆的，按圆形区域命中，别让四个角白占位置。
    func hitTest(_ layer: Layer, at point: CGPoint, tolerance: Double) -> Bool {
        let rect = layer.rect.cg
        return hypot(point.x - rect.midX, point.y - rect.midY) <= rect.width / 2 + tolerance
    }

    func resize(
        _ original: Layer, handle: ResizeHandle, delta: CGPoint, pixelScale: Double
    ) -> Layer {
        var layer = original
        layer.rect = LRect(Self.square(handle: handle, delta: delta, original: original.rect.cg))
        return layer
    }

    /// 实心圆 + 白色粗体数字居中。字号从圆径推导，两位数也放得下。
    func draw(_ layer: Layer, in ctx: CGContext) {
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

    /// 保持圆形：直径 d 拖角取 max(w, h)、拖边取被拖的那一维；
    /// 被拖控制点的对侧保持不动（拖边时另一轴居中锚定）。
    static func square(handle: ResizeHandle, delta: CGPoint, original: CGRect) -> CGRect {
        let applied = handle.apply(delta: delta, to: original)
        let d: CGFloat
        switch handle {
        case .top, .bottom: d = applied.height
        case .left, .right: d = applied.width
        default:            d = max(applied.width, applied.height)
        }

        let minX: CGFloat
        switch handle {
        case .topLeft, .left, .bottomLeft:       minX = original.maxX - d
        case .topRight, .right, .bottomRight:    minX = original.minX
        default:                                 minX = original.midX - d / 2
        }
        let minY: CGFloat
        switch handle {
        case .topLeft, .top, .topRight:          minY = original.minY
        case .bottomLeft, .bottom, .bottomRight: minY = original.maxY - d
        default:                                 minY = original.midY - d / 2
        }
        return CGRect(x: minX, y: minY, width: d, height: d)
    }
}
