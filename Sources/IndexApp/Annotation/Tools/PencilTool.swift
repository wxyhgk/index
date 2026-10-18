import AppKit

/// 自由画笔：跟手画路径，Catmull-Rom 平滑。
/// 输入方式是 `.stroke`（一系列点），不是拖两点或点击。
/// 画完提交后只能整体移动（无缩放控制点），和 PixPin 的铅笔一致。
struct PencilTool: AnnotationToolDescriptor {
    let tool = AnnotationTool.pencil
    let axes: [ToolStyleAxis] = [.color, .width]
    let defaultStyle = ToolStyle()
    let input = ToolInput.stroke
    let shortcut: (keyCode: UInt16, label: String)? = (KeyCode.b, "B")
    let isPinnedToBar = true

    /// 路径点存进 layer.strokePoints，rect 是包围盒（移动 / 命中用）。
    func makeLayer(_ context: ToolLayerContext) -> Layer {
        var layer = baseLayer(context)
        layer.strokePoints = context.strokePoints
        guard !context.strokePoints.isEmpty else { return layer }
        let pad = layer.lineWidth / 2
        layer.rect = LRect(context.strokeBoundingRect.insetBy(dx: -pad, dy: -pad))
        return layer
    }

    /// 点到任一路径点距离 ≤ lineWidth/2 + tolerance。
    func hitTest(_ layer: Layer, at point: CGPoint, tolerance: Double) -> Bool {
        layer.hitTestStroke(at: point, pad: layer.lineWidth / 2 + tolerance)
    }

    /// 画笔无缩放控制点，只能整体移动。
    var resizeHandles: [ResizeHandle] { [] }

    /// 画笔整体移动后同步路径点。
    func afterSourceMove(_ layer: Layer, by delta: CGPoint) -> Layer {
        guard var points = layer.strokePoints, !points.isEmpty else { return layer }
        for i in points.indices { points[i].x += delta.x; points[i].y += delta.y }
        var result = layer
        result.strokePoints = points
        return result
    }

    /// Catmull-Rom → 贝塞尔平滑（≥4 点）；短路径退化为折线。
    func draw(_ layer: Layer, in ctx: CGContext) {
        guard (layer.strokePoints?.count ?? 0) >= 2 else { return }
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
