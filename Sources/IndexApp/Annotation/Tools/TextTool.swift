import AppKit
import CoreText

/// 文字：点一下落一个锚点，接着进编辑态（编辑态本身由 `AnnotationState` 管，
/// 它是跨工具的输入状态，不属于某一个工具）。
///
/// `rect` 只存锚点（w/h 恒为 0），实际范围由 `Layer.handleBounds` 按当前字号
/// 现量出来 —— 字体参数必须与这里的绘制一致，否则控制点会飘在文字外。
///
/// 支持多行（Shift+Return 插入 \n）、粗体/斜体、光标定位与方向键移动。
struct TextTool: AnnotationToolDescriptor {
    let tool = AnnotationTool.text
    let axes: [ToolStyleAxis] = [.color, .fontSize, .bold, .italic, .textBg, .textAlign]
    let defaultStyle = ToolStyle()
    let input = ToolInput.click
    let shortcut: (keyCode: UInt16, label: String)? = (KeyCode.t, "T")
    let isPinnedToBar = true

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

        let isBold = layer.bold == 1
        let isItalic = layer.italic == 1
        let weight: NSFont.Weight = isBold ? .bold : .regular
        var font = NSFont.systemFont(ofSize: layer.fontSize, weight: weight)
        if isItalic {
            font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        }
        let color = NSColor(cgColor: layer.color.cg) ?? .systemRed
        let lines = layer.text.components(separatedBy: "\n")
        let lineSpacing = layer.fontSize * 1.3
        let rect = layer.rect.cg

        let align = layer.textAlign ?? 0

        // 预计算每行的 CTLine 和宽度（背景 + 对齐共用）
        var maxWidth: CGFloat = 0
        let ctLines: [(line: CTLine, width: CGFloat)] = lines.map { line in
            let attributed = NSAttributedString(string: line, attributes: [
                .font: font,
                .foregroundColor: color
            ])
            let ctLine = CTLineCreateWithAttributedString(attributed)
            let w = CGFloat(CTLineGetTypographicBounds(ctLine, nil, nil, nil))
            maxWidth = max(maxWidth, w)
            return (ctLine, w)
        }

        ctx.saveGState()

        // 文字背景（半透明圆角矩形，铺在文字下面）
        if let bg = layer.textBg, bg != 0 {
            let pad = layer.fontSize * 0.15
            let bgRect = CGRect(
                x: rect.minX - pad, y: rect.minY - pad,
                width: maxWidth + pad * 2,
                height: CGFloat(lines.count) * lineSpacing + pad * 2
            )
            ctx.setFillColor(
                bg == 1 ? CGColor(gray: 0, alpha: 0.55) : CGColor(gray: 1, alpha: 0.7)
            )
            ctx.addPath(CGPath(roundedRect: bgRect, cornerWidth: 4, cornerHeight: 4, transform: nil))
            ctx.fillPath()
        }

        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        ctx.setTextDrawingMode(.fill)

        var y = rect.minY
        for (ctLine, lineWidth) in ctLines {
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            CTLineGetTypographicBounds(ctLine, &ascent, &descent, nil)
            // 按对齐方式偏移 x
            var x: CGFloat = rect.minX
            if align == 1 { x = rect.minX + (maxWidth - lineWidth) / 2 }
            else if align == 2 { x = rect.minX + maxWidth - lineWidth }
            ctx.textPosition = CGPoint(x: x, y: y + ascent)
            CTLineDraw(ctLine, ctx)
            y += lineSpacing
        }
        ctx.restoreGState()
    }
}
