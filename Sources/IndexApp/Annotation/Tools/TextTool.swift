import AppKit
import CoreText

/// 文字：点一下落一个锚点，接着进编辑态（编辑态本身由 `AnnotationState` 管，
/// 它是跨工具的输入状态，不属于某一个工具）。
///
/// `rect` 只存锚点（w/h 恒为 0），实际范围由 `Layer.handleBounds` 按当前字号
/// 现量出来 —— 字体参数必须与这里的绘制一致，否则控制点会飘在文字外。
///
/// 支持多行（Shift+Return 插入 \n）和描边（fillStroke，浅色底上白色文字可见）。
struct TextTool: AnnotationToolDescriptor {
    let tool = AnnotationTool.text
    let axes: [ToolStyleAxis] = [.color, .fontSize]
    let defaultStyle = ToolStyle()
    let input = ToolInput.click
    let shortcut: (keyCode: UInt16, label: String)? = (KeyCode.t, "T")
    let isPinnedToBar = true

    /// 描边宽 = 字号 × 0.08（与字号联动，视觉上始终协调）。
    private static let strokeRatio: CGFloat = 0.08

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
        let color = NSColor(cgColor: layer.color.cg) ?? .systemRed
        let lines = layer.text.components(separatedBy: "\n")
        let lineSpacing = layer.fontSize * 1.3

        ctx.saveGState()
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        ctx.setLineWidth(layer.fontSize * Self.strokeRatio)
        ctx.setStrokeColor(color.withAlphaComponent(0.8).cgColor)
        ctx.setTextDrawingMode(.fillStroke)

        var y = layer.rect.y
        for line in lines {
            let attributed = NSAttributedString(string: line, attributes: [
                .font: font,
                .foregroundColor: color
            ])
            let ctLine = CTLineCreateWithAttributedString(attributed)
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            CTLineGetTypographicBounds(ctLine, &ascent, &descent, nil)
            ctx.textPosition = CGPoint(x: layer.rect.x, y: y + ascent)
            CTLineDraw(ctLine, ctx)
            y += lineSpacing
        }
        ctx.restoreGState()
    }
}
