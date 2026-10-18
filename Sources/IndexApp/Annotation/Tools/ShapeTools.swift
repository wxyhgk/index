import AppKit

// 简单的封闭形状工具：拖一个矩形/椭圆、按边框命中、控制点缩放。
// 契约的默认实现大部分够用，各自只补命中与绘制。

struct RectTool: AnnotationToolDescriptor {
    let tool = AnnotationTool.rect
    let axes: [ToolStyleAxis] = [.color, .width, .fillMode, .cornerRadius]
    let defaultStyle = ToolStyle()
    let shortcut: (keyCode: UInt16, label: String)? = (KeyCode.r, "R")
    let isPinnedToBar = true

    /// 只命中边框（外扩 lineWidth/2 + tolerance，内缩同量）。
    /// 点在内部 = 画新形状（同心矩形），点在边框上 = 选中/拖动。
    func hitTest(_ layer: Layer, at point: CGPoint, tolerance: Double) -> Bool {
        let rect = layer.rect.cg
        let pad = layer.lineWidth / 2 + tolerance
        let outer = rect.insetBy(dx: -pad, dy: -pad)
        guard outer.contains(point) else { return false }
        let inner = rect.insetBy(dx: pad, dy: pad)
        if inner.width <= 0 || inner.height <= 0 { return true }
        return !inner.contains(point)
    }

    func draw(_ layer: Layer, in ctx: CGContext) {
        let mode = layer.fillMode ?? 0
        let color = layer.color.cg
        let rect = layer.rect.cg
        let corner = CGFloat(min(layer.cornerRadius ?? 0, min(rect.width, rect.height) / 2))

        let path: CGPath = corner > 0
            ? CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil)
            : CGPath(rect: rect, transform: nil)

        ctx.saveGState()
        switch mode {
        case 1:
            ctx.setFillColor(color)
            ctx.addPath(path)
            ctx.fillPath()
        case 2:
            ctx.setFillColor(color)
            ctx.addPath(path)
            ctx.fillPath()
            ctx.setStrokeColor(color)
            ctx.setLineWidth(layer.lineWidth)
            ctx.addPath(path)
            ctx.strokePath()
        default:
            ctx.setStrokeColor(color)
            ctx.setLineWidth(layer.lineWidth)
            ctx.addPath(path)
            ctx.strokePath()
        }
        ctx.restoreGState()
    }
}

struct EllipseTool: AnnotationToolDescriptor {
    let tool = AnnotationTool.ellipse
    let axes: [ToolStyleAxis] = [.color, .width, .fillMode]
    let defaultStyle = ToolStyle()
    let shortcut: (keyCode: UInt16, label: String)? = (KeyCode.o, "O")

    /// 只命中椭圆边框（点到椭圆边距离 ≤ lineWidth/2 + tolerance）。
    /// 点在内部 = 画新形状（同心椭圆），点在边框上 = 选中/拖动。
    func hitTest(_ layer: Layer, at point: CGPoint, tolerance: Double) -> Bool {
        let rect = layer.rect.cg
        let cx = rect.midX, cy = rect.midY
        let rx = rect.width / 2, ry = rect.height / 2
        guard rx > 0, ry > 0 else { return false }
        let nx = (point.x - cx) / rx
        let ny = (point.y - cy) / ry
        let d = (nx * nx + ny * ny - 1) * (rx + ry) / (2 * sqrt(nx * nx * ry * ry + ny * ny * rx * rx))
        return abs(d) <= layer.lineWidth / 2 + tolerance
    }

    func draw(_ layer: Layer, in ctx: CGContext) {
        let mode = layer.fillMode ?? 0
        let color = layer.color.cg
        switch mode {
        case 1:
            ctx.setFillColor(color)
            ctx.fillEllipse(in: layer.rect.cg)
        case 2:
            ctx.setFillColor(color)
            ctx.fillEllipse(in: layer.rect.cg)
            ctx.setStrokeColor(color)
            ctx.setLineWidth(layer.lineWidth)
            ctx.strokeEllipse(in: layer.rect.cg)
        default:
            ctx.setStrokeColor(color)
            ctx.setLineWidth(layer.lineWidth)
            ctx.strokeEllipse(in: layer.rect.cg)
        }
    }
}
