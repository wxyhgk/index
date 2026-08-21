import AppKit
import CoreText

/// 文字：点一下落一个锚点，接着进编辑态（编辑态本身由 `AnnotationState` 管，
/// 它是跨工具的输入状态，不属于某一个工具）。
///
/// `rect` 只存锚点（w/h 恒为 0），实际范围由 `Layer.handleBounds` 按当前字号
/// 现量出来 —— 字体参数必须与这里的绘制一致，否则控制点会飘在文字外。
struct TextTool: AnnotationToolDescriptor {
    let tool = AnnotationTool.text
    // 吃字号，不吃线宽 —— 旧版本这两者共用一个下标，
    // 调矩形边框粗细会顺手改掉文字大小。
    let axes: [ToolStyleAxis] = [.color, .fontSize]
    let defaultStyle = ToolStyle()
    let input = ToolInput.click
    let shortcut: (keyCode: UInt16, label: String)? = (KeyCode.t, "T")
    let isPinnedToBar = true

    func makeLayer(_ context: ToolLayerContext) -> Layer {
        var layer = baseLayer(context)
        layer.text = ""
        return layer
    }

    /// 拖控制点改的是**字号**，不是矩形。
    func resize(
        _ original: Layer, handle: ResizeHandle, delta: CGPoint, pixelScale: Double
    ) -> Layer {
        var layer = original
        let bounds = original.handleBounds
        let resized = handle.apply(delta: delta, to: bounds)
        layer.rect.x = resized.minX
        layer.rect.y = resized.minY
        if bounds.height > 0 {
            layer.fontSize = max(4, original.fontSize * resized.height / bounds.height)
        }
        return layer
    }

    func meetsMinimumSize(_ layer: Layer) -> Bool {
        layer.fontSize >= 4
    }

    func draw(_ layer: Layer, in ctx: CGContext) {
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
}
