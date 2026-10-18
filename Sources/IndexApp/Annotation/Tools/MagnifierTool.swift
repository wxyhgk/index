import AppKit

/// 放大镜：框选区域放大显示。
/// `rect` = 源区域（被放大的内容区域），放大镜显示区域自动计算在源区域旁边。
/// 放大内容需要 baseImage，由 `AnnotationRenderer.drawMagnifierContent` 绘制。
struct MagnifierTool: AnnotationToolDescriptor {
    let tool = AnnotationTool.magnifier
    let axes: [ToolStyleAxis] = []
    let defaultStyle = ToolStyle()
    let input = ToolInput.drag
    let shortcut: (UInt16, String)? = (KeyCode.z, "Z")
    let isPinnedToBar = true

    func makeLayer(_ context: ToolLayerContext) -> Layer {
        var layer = baseLayer(context)
        layer.magnifierZoom = 2.0
        layer.color = LColor(r: 0.2, g: 0.5, b: 1.0, a: 1)
        layer.lineWidth = 2.0
        layer.magnifierDisplayOrigin = Self.displayRect(source: layer.rect.cg, zoom: 2.0, canvas: .infinite).origin
        return layer
    }

    /// 源区域或放大镜显示区域内。
    func hitTest(_ layer: Layer, at point: CGPoint, tolerance: Double) -> Bool {
        let source = layer.rect.cg.insetBy(dx: -tolerance, dy: -tolerance)
        if source.contains(point) { return true }
        let zoom = layer.magnifierZoom ?? 2.0
        let origin = layer.magnifierDisplayOrigin ?? Self.displayRect(source: layer.rect.cg, zoom: zoom, canvas: .infinite).origin
        let display = CGRect(origin: origin, size: CGSize(width: layer.rect.cg.width * zoom, height: layer.rect.cg.height * zoom))
        return display.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
    }

    var resizeHandles: [ResizeHandle] {
        [.topLeft, .top, .topRight, .bottomLeft, .bottom, .bottomRight, .left, .right]
    }

    // MARK: 移动语义

    func moveTarget(_ layer: Layer, at point: CGPoint) -> LayerMoveTarget {
        let zoom = layer.magnifierZoom ?? 2.0
        let origin = layer.magnifierDisplayOrigin
            ?? Self.displayRect(source: layer.rect.cg, zoom: zoom, canvas: .infinite).origin
        let display = CGRect(origin: origin, size: CGSize(width: layer.rect.cg.width * zoom, height: layer.rect.cg.height * zoom))
        return display.contains(point) ? .specialRegion : .source
    }

    func moveSpecialRegion(_ layer: Layer, by delta: CGPoint) -> Layer? {
        guard var origin = layer.magnifierDisplayOrigin else { return nil }
        origin.x += delta.x
        origin.y += delta.y
        var result = layer
        result.magnifierDisplayOrigin = origin
        return result
    }

    func afterSourceMove(_ layer: Layer, by delta: CGPoint) -> Layer {
        guard var origin = layer.magnifierDisplayOrigin else { return layer }
        origin.x += delta.x
        origin.y += delta.y
        var result = layer
        result.magnifierDisplayOrigin = origin
        return result
    }

    // MARK: 滚轮调整

    var supportsScroll: Bool { true }

    func scrollAdjust(_ layer: Layer, deltaY: CGFloat) -> Layer? {
        guard deltaY != 0 else { return nil }
        let oldZoom = layer.magnifierZoom ?? 2.0
        let newZoom = max(1.0, min(4.0, oldZoom + (deltaY > 0 ? 0.25 : -0.25)))
        guard newZoom != oldZoom else { return nil }
        var result = layer
        result.magnifierZoom = newZoom
        return result
    }

    /// 在矢量边框之下画放大内容（白色背景 + 源区域放大像素）。
    func drawBelow(_ layer: Layer, preview: CGImage?, baseImage: CGImage?, canvasSize: CGSize, in ctx: CGContext) {
        guard let baseImage, canvasSize != .zero else { return }
        let source = layer.rect.cg
        guard source.width >= 4, source.height >= 4 else { return }
        let zoom = layer.magnifierZoom ?? 2.0
        let displayOrigin = layer.magnifierDisplayOrigin
            ?? Self.displayRect(source: source, zoom: zoom, canvas: .infinite).origin
        let display = CGRect(origin: displayOrigin, size: CGSize(width: source.width * zoom, height: source.height * zoom))

        ctx.saveGState()
        let corner: CGFloat = 8
        let path = CGPath(roundedRect: display, cornerWidth: corner, cornerHeight: corner, transform: nil)
        ctx.addPath(path)
        ctx.clip()
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.92).cgColor)
        ctx.fillPath()
        ctx.translateBy(x: display.minX, y: display.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.scaleBy(x: zoom, y: zoom)
        ctx.translateBy(x: -source.minX, y: -(canvasSize.height - source.maxY))
        ctx.draw(baseImage, in: CGRect(origin: .zero, size: canvasSize))
        ctx.restoreGState()
    }

    /// 源区域边框 + 连接线 + 放大镜区域边框。
    func draw(_ layer: Layer, in ctx: CGContext) {
        let source = layer.rect.cg
        guard source.width >= 4, source.height >= 4 else { return }
        let zoom = layer.magnifierZoom ?? 2.0
        let displayOrigin = layer.magnifierDisplayOrigin ?? Self.displayRect(source: source, zoom: zoom, canvas: .infinite).origin
        let display = CGRect(origin: displayOrigin, size: CGSize(width: source.width * zoom, height: source.height * zoom))

        // 连接线：源区域右边缘中点 → 放大镜左边缘中点
        ctx.saveGState()
        ctx.setStrokeColor(layer.color.cg)
        ctx.setLineWidth(max(1, layer.lineWidth / 4))
        ctx.setLineDash(phase: 0, lengths: [4, 3])
        ctx.move(to: CGPoint(x: source.maxX, y: source.midY))
        ctx.addLine(to: CGPoint(x: display.minX, y: display.midY))
        ctx.strokePath()
        ctx.restoreGState()

        // 源区域边框
        ctx.saveGState()
        ctx.setStrokeColor(layer.color.cg)
        ctx.setLineWidth(layer.lineWidth)
        ctx.stroke(source)
        ctx.restoreGState()

        // 放大镜区域：边框（白色背景由 drawMagnifierContent 画在放大内容下面）。
        let corner: CGFloat = 8
        let path = CGPath(roundedRect: display, cornerWidth: corner, cornerHeight: corner, transform: nil)
        ctx.saveGState()
        ctx.addPath(path)
        ctx.setStrokeColor(layer.color.cg)
        ctx.setLineWidth(max(1.5, layer.lineWidth / 3))
        ctx.strokePath()
        ctx.restoreGState()
    }

    /// 放大镜显示区域：源区域右侧偏移 20pt，大小 = 源区域 × 倍率。
    /// 右边放不下时放上方。
    static func displayRect(source: CGRect, zoom: Double, canvas: CGRect) -> CGRect {
        let w = source.width * zoom
        let h = source.height * zoom
        let offset: CGFloat = 20
        var x = source.maxX + offset
        var y = source.midY - h / 2
        if canvas != .infinite, x + w > canvas.maxX {
            x = source.midX - w / 2
            y = source.minY - h - offset
            if y < canvas.minY { y = source.maxY + offset }
        }
        return CGRect(x: x, y: y, width: w, height: h)
    }
}
