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
    /// 自动吸附水平 / 垂直 / 45°（阈值 5°）。
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
        // 角度吸附：对拖动的端点做约束
        if handle == .bottomRight {
            let snapped = Self.snapAngle(
                start: original.rect.start,
                end: CGPoint(x: original.rect.start.x + layer.rect.w, y: original.rect.start.y + layer.rect.h)
            )
            layer.rect.w = snapped.x - original.rect.start.x
            layer.rect.h = snapped.y - original.rect.start.y
        } else {
            let snapped = Self.snapAngle(
                start: CGPoint(x: original.rect.start.x + layer.rect.w, y: original.rect.start.y + layer.rect.h),
                end: original.rect.start
            )
            layer.rect.x = snapped.x
            layer.rect.y = snapped.y
            layer.rect.w = original.rect.start.x - snapped.x
            layer.rect.h = original.rect.start.y - snapped.y
        }
        return layer
    }

    /// 将 end 点吸附到 start 的水平 / 垂直 / 45° 方向（阈值 5°）。
    private static func snapAngle(start: CGPoint, end: CGPoint) -> CGPoint {
        let dx = end.x - start.x
        let dy = end.y - start.y
        guard abs(dx) > 1 || abs(dy) > 1 else { return end }
        let angle = atan2(dy, dx)
        let threshold: CGFloat = 5 * .pi / 180
        let length = hypot(dx, dy)
        // 候选吸附角：0, ±45°, ±90°, ±135°, 180°
        let candidates: [CGFloat] = [0, .pi/4, -.pi/4, .pi/2, -.pi/2, 3 * .pi / 4, -3 * .pi / 4, .pi, -.pi]
        for candidate in candidates {
            let diff = abs(angle - candidate)
            if diff < threshold {
                return CGPoint(x: start.x + cos(candidate) * length, y: start.y + sin(candidate) * length)
            }
        }
        return end
    }

    /// 只要长度别缩没。
    func meetsMinimumSize(_ layer: Layer) -> Bool {
        max(abs(layer.rect.w), abs(layer.rect.h)) >= ToolGeometry.minimumSide
    }
}

struct LineTool: SegmentTool {
    let tool = AnnotationTool.line
    let axes: [ToolStyleAxis] = [.color, .width, .fillMode]
    let defaultStyle = ToolStyle()
    let shortcut: (keyCode: UInt16, label: String)? = (KeyCode.l, "L")

    func draw(_ layer: Layer, in ctx: CGContext) {
        let mode = layer.fillMode ?? 0
        let color = layer.color.cg
        let width = layer.lineWidth
        let a = layer.rect.start
        let b = layer.rect.end

        ctx.saveGState()
        ctx.setStrokeColor(color)
        ctx.setLineWidth(width)
        ctx.setLineCap(.round)

        // 虚线模式（fillMode=1）
        if mode == 1 {
            let dash: [CGFloat] = [width * 2, width * 1.5]
            ctx.setLineDash(phase: 0, lengths: dash)
        }

        ctx.move(to: a)
        ctx.addLine(to: b)
        ctx.strokePath()
        ctx.restoreGState()

        // 端帽装饰（fillMode=2）：两端画实心圆点
        if mode == 2 {
            ctx.saveGState()
            ctx.setFillColor(color)
            let dotRadius = max(width * 0.6, 3)
            for point in [a, b] {
                ctx.fillEllipse(in: CGRect(
                    x: point.x - dotRadius, y: point.y - dotRadius,
                    width: dotRadius * 2, height: dotRadius * 2
                ))
            }
            ctx.restoreGState()
        }
    }
}

struct ArrowTool: SegmentTool {
    let tool = AnnotationTool.arrow
    let axes: [ToolStyleAxis] = [.color, .width, .headSize]
    let defaultStyle = ToolStyle()
    let shortcut: (keyCode: UInt16, label: String)? = (KeyCode.a, "A")
    let isPinnedToBar = true

    func draw(_ layer: Layer, in ctx: CGContext) {
        let a = layer.rect.start
        let b = layer.rect.end
        let width = CGFloat(layer.lineWidth)
        let headScale = CGFloat(layer.headScale ?? 3.0)
        let headLength = max(10, width * headScale)
        let angle = atan2(b.y - a.y, b.x - a.x)
        guard hypot(b.x - a.x, b.y - a.y) > 1 else { return }

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
