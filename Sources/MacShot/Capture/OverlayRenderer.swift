import AppKit

/// 选区覆盖层的全部绘制逻辑。无状态 —— 输入模型，输出像素。
enum OverlayRenderer {

    @MainActor
    static func draw(
        model: SelectionModel,
        annotation: AnnotationState,
        slots: [ToolbarSlot],
        hoveredControlID: String?,
        isPrimaryScreen: Bool,
        magnifier: (sample: PixelSample, cursor: CGPoint)?,
        in bounds: CGRect,
        ctx: CGContext
    ) {
        // 冻结画面本身由 CALayer 承载，这里**绝不重画位图** ——
        // 拖拽时每帧重采样一张 4K 位图会直接把主线程压垮。
        // 压暗用「整屏 + 选区」的 even-odd 路径一次填充，纯平色，几乎零成本。
        let dimPath = NSBezierPath(rect: bounds)
        let globalRect = model.activeRect.flatMap { $0.isEmpty ? nil : $0 }
        let local = globalRect.map { toLocal($0, in: model) }

        if let local {
            dimPath.appendRect(local)
            dimPath.windingRule = .evenOdd
        }
        NSColor.black.withAlphaComponent(0.42).setFill()
        dimPath.fill()

        guard let globalRect, let local else {
            if isPrimaryScreen && !model.isInactive {
                drawHint(in: bounds)
            }
            if let magnifier {
                MagnifierRenderer.draw(
                    sample: magnifier.sample, at: magnifier.cursor, in: bounds, ctx: ctx
                )
            }
            return
        }

        // 标注画在选区内，用的是和最终导出**同一份**绘制代码，所见即所得。
        drawAnnotations(annotation, clippedTo: local, in: bounds, ctx: ctx)

        let isWindowHint = model.isWindowHint
        ctx.setStrokeColor((isWindowHint ? NSColor.systemBlue : NSColor.white).cgColor)
        ctx.setLineWidth(isWindowHint ? 3 : 1.5)
        ctx.stroke(local.insetBy(dx: -0.75, dy: -0.75))

        drawSizeLabel(
            for: globalRect,
            near: local,
            ownerName: isWindowHint ? model.hoveredWindow?.ownerName : nil,
            scale: model.snapshot.scale,
            in: bounds
        )

        // 有标注工具在手时隐藏控制点，避免和画布上的操作混淆。
        if model.showsHandles && annotation.tool == nil {
            drawHandles(in: local)
        }

        if model.phase == .confirmed {
            ToolbarRenderer.draw(
                slots,
                hovered: hoveredControlID,
                context: ToolbarContext(annotation: annotation, scope: .capture, perform: { _ in })
            )
        }

        // 放大镜画在最上层，否则会被选区边框和工具条盖住。
        if let magnifier {
            MagnifierRenderer.draw(
                sample: magnifier.sample, at: magnifier.cursor, in: bounds, ctx: ctx
            )
        }
    }

    // MARK: - 标注

    @MainActor
    private static func drawAnnotations(
        _ annotation: AnnotationState,
        clippedTo selection: CGRect,
        in bounds: CGRect,
        ctx: CGContext
    ) {
        let layers = annotation.displayLayers
        guard !layers.isEmpty else { return }

        ctx.saveGState()
        ctx.clip(to: selection)
        // 翻成「显示器局部、左上原点、Y 向下」—— 标注图层就存在这个坐标系里。
        ctx.translateBy(x: 0, y: bounds.height)
        ctx.scaleBy(x: 1, y: -1)
        AnnotationRenderer.draw(
            layers,
            pixelatePreviews: annotation.pixelatePreviews,
            in: ctx
        )
        ctx.restoreGState()
    }

    // MARK: - 坐标

    @MainActor
    private static func toLocal(_ global: CGRect, in model: SelectionModel) -> CGRect {
        CGRect(
            x: global.origin.x - model.bounds.origin.x,
            y: global.origin.y - model.bounds.origin.y,
            width: global.width,
            height: global.height
        )
    }

    // MARK: - 局部元素

    private static func drawHint(in bounds: CGRect) {
        let text = "拖拽选区 · 单击窗口 · ESC 取消"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.85)
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        (text as NSString).draw(
            at: NSPoint(x: (bounds.width - size.width) / 2, y: bounds.height * 0.62),
            withAttributes: attrs
        )
    }

    private static func drawSizeLabel(
        for globalRect: CGRect,
        near local: CGRect,
        ownerName: String?,
        scale: CGFloat,
        in bounds: CGRect
    ) {
        var text = "\(Int(globalRect.width * scale)) × \(Int(globalRect.height * scale))"
        if let ownerName {
            text = "\(ownerName)  \(text)"
        }

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let textSize = (text as NSString).size(withAttributes: attrs)
        let padding: CGFloat = 6
        var box = NSRect(
            x: local.minX,
            y: local.maxY + 6,
            width: textSize.width + padding * 2,
            height: textSize.height + padding
        )
        if box.maxY > bounds.maxY { box.origin.y = local.minY - box.height - 6 }
        if box.maxX > bounds.maxX { box.origin.x = bounds.maxX - box.width - 4 }
        box.origin.x = max(4, box.origin.x)

        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5).fill()
        (text as NSString).draw(
            at: NSPoint(x: box.minX + padding, y: box.minY + padding / 2),
            withAttributes: attrs
        )
    }

    /// 8 个调整控制点。选区太小时只画四角，否则会糊成一团。
    private static func drawHandles(in local: CGRect) {
        let size: CGFloat = 7
        let cornersOnly = local.width < 40 || local.height < 40

        let handles: [SelectionModel.Handle] = cornersOnly
            ? [.topLeft, .topRight, .bottomRight, .bottomLeft]
            : SelectionModel.Handle.resizeHandles

        for handle in handles {
            let center = handle.point(in: local)
            let box = NSRect(
                x: center.x - size / 2,
                y: center.y - size / 2,
                width: size,
                height: size
            )
            let path = NSBezierPath(roundedRect: box, xRadius: 1.5, yRadius: 1.5)
            NSColor.white.setFill()
            path.fill()
            NSColor.black.withAlphaComponent(0.45).setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }
}
