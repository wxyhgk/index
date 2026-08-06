import AppKit

/// 线段类工具的共同语义：两端控制点、按点到线段的距离命中、长度决定死活。
/// 直线与箭头只差绘制，行为完全一致，所以合在一个协议里。
protocol SegmentTool: AnnotationToolDescriptor {}

extension SegmentTool {

    /// 只有两端（`topLeft` ↔ `rect.start`、`bottomRight` ↔ `rect.end`）。
    var resizeHandles: [ResizeHandle] { [.topLeft, .bottomRight] }

    /// 按 start/end 取端点，而不是外接框的角 —— 负宽高合法，方向不能丢。
    func handleLocation(_ handle: ResizeHandle, on layer: Layer) -> CGPoint {
        handle == .topLeft ? layer.rect.start : layer.rect.end
    }

    /// 两端画成圆点，不是方块。
    var usesEndpointHandles: Bool { true }

    /// 按点到线段的距离判定，带一圈容差方便点中细线 ——
    /// 用外接矩形的话，对角线的另外两个角会白白吃掉点击。
    func hitTest(_ layer: Layer, at point: CGPoint, tolerance: Double) -> Bool {
        ToolGeometry.distance(from: point, toSegment: layer.rect.start, layer.rect.end)
            <= tolerance + layer.lineWidth / 2
    }

    /// 拖端点，不是整形矩形 —— 负宽高合法，方向不能丢。
    func resize(
        _ original: Layer, handle: ResizeHandle, delta: CGPoint, pixelScale: Double
    ) -> Layer {
        var layer = original
        if handle == .topLeft {
            layer.rect.x = original.rect.x + delta.x
            layer.rect.y = original.rect.y + delta.y
            layer.rect.w = original.rect.w - delta.x
            layer.rect.h = original.rect.h - delta.y
        } else {
            layer.rect.w = original.rect.w + delta.x
            layer.rect.h = original.rect.h + delta.y
        }
        return layer
    }

    /// 只要长度别缩没。
    func meetsMinimumSize(_ layer: Layer) -> Bool {
        max(abs(layer.rect.w), abs(layer.rect.h)) >= ToolGeometry.minimumSide
    }
}

struct LineTool: SegmentTool {
    let tool = AnnotationTool.line
    let axes: [ToolStyleAxis] = [.color, .width]
    let defaultStyle = ToolStyle()
    let shortcut: (keyCode: UInt16, label: String)? = (KeyCode.l, "L")

    func draw(_ layer: Layer, in ctx: CGContext) {
        ctx.setStrokeColor(layer.color.cg)
        ctx.setLineWidth(layer.lineWidth)
        ctx.setLineCap(.round)
        ctx.move(to: layer.rect.start)
        ctx.addLine(to: layer.rect.end)
        ctx.strokePath()
    }
}

struct ArrowTool: SegmentTool {
    let tool = AnnotationTool.arrow
    let axes: [ToolStyleAxis] = [.color, .width]
    let defaultStyle = ToolStyle()
    let shortcut: (keyCode: UInt16, label: String)? = (KeyCode.a, "A")
    let isPinnedToBar = true

    func draw(_ layer: Layer, in ctx: CGContext) {
        let a = layer.rect.start
        let b = layer.rect.end
        let width = CGFloat(layer.lineWidth)
        let headLength = max(12, width * 4)
        let angle = atan2(b.y - a.y, b.x - a.x)
        guard hypot(b.x - a.x, b.y - a.y) > 1 else { return }

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
}
