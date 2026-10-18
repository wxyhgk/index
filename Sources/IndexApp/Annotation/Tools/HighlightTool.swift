import AppKit

/// 自由荧光笔：跟手画路径，Catmull-Rom 平滑。
/// 粗的半透明笔触（默认 24pt 宽、40% 透明度），和画笔一样是 `.stroke` 输入。
/// 旧图层（矩形高亮，无 strokePoints）兼容渲染为半透明矩形。
struct HighlightTool: AnnotationToolDescriptor {
    let tool = AnnotationTool.highlight
    let axes: [ToolStyleAxis] = [.color, .width, .opacity]
    let defaultStyle = ToolStyle(colorIndex: 1, widthIndex: 11)
    let input = ToolInput.stroke
    let shortcut: (keyCode: UInt16, label: String)? = (KeyCode.h, "H")

    /// 路径点存进 layer.strokePoints，rect 是包围盒。
    func makeLayer(_ context: ToolLayerContext) -> Layer {
        var layer = baseLayer(context)
        layer.strokePoints = context.strokePoints
        guard !context.strokePoints.isEmpty else { return layer }
        let pad = layer.lineWidth / 2
        layer.rect = LRect(context.strokeBoundingRect.insetBy(dx: -pad, dy: -pad))
        return layer
    }

    /// 点到任一路径点距离 ≤ lineWidth/2 + tolerance。旧矩形图层退回外接框。
    func hitTest(_ layer: Layer, at point: CGPoint, tolerance: Double) -> Bool {
        if layer.strokePoints?.isEmpty == false {
            return layer.hitTestStroke(at: point, pad: layer.lineWidth / 2 + tolerance)
        }
        return layer.rect.cg.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
    }

    /// 荧光笔无缩放控制点，只能整体移动。
    var resizeHandles: [ResizeHandle] { [] }

    /// 荧光笔整体移动后同步路径点。
    func afterSourceMove(_ layer: Layer, by delta: CGPoint) -> Layer {
        guard var points = layer.strokePoints, !points.isEmpty else { return layer }
        for i in points.indices { points[i].x += delta.x; points[i].y += delta.y }
        var result = layer
        result.strokePoints = points
        return result
    }

    /// Catmull-Rom → 贝塞尔平滑（≥4 点）；半透明粗笔触。
    /// 旧图层（无 strokePoints）退回画半透明矩形。
    func draw(_ layer: Layer, in ctx: CGContext) {
        guard let points = layer.strokePoints, points.count >= 2 else {
            ctx.saveGState()
            ctx.setBlendMode(.normal)
            ctx.setFillColor(layer.color.cg)
            ctx.fill(layer.rect.cg)
            ctx.restoreGState()
            return
        }

        ctx.saveGState()
        ctx.setStrokeColor(layer.color.cg)
        ctx.setLineWidth(layer.lineWidth)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        layer.addStrokePath(to: ctx)
        ctx.strokePath()
        ctx.restoreGState()
    }
}
