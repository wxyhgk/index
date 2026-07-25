import AppKit

/// 选区覆盖层的全部绘制逻辑。无状态 —— 输入模型，输出像素。
enum OverlayRenderer {

    @MainActor
    static func draw(
        model: SelectionModel,
        annotation: AnnotationState,
        slots: [ToolbarSlot],
        hoveredItem: ToolbarItem?,
        isPrimaryScreen: Bool,
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
            drawToolbar(slots, hovered: hoveredItem, annotation: annotation)
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

        for layer in layers where layer.kind == .pixelate {
            drawPixelate(layer, preview: annotation.pixelatePreviews[layer.id], in: ctx)
        }
        LayerRenderer.drawVectors(layers, in: ctx)

        ctx.restoreGState()
    }

    /// 马赛克贴片是提交时预先算好的；正在拖的那个还没有，先用灰块占位。
    private static func drawPixelate(_ layer: Layer, preview: CGImage?, in ctx: CGContext) {
        let rect = layer.rect.cg
        guard rect.width >= 1, rect.height >= 1 else { return }

        guard let preview else {
            ctx.setFillColor(NSColor(calibratedWhite: 0.55, alpha: 0.9).cgColor)
            ctx.fill(rect)
            return
        }

        // 上下文此刻是 Y 向下的，画位图要再翻一次。
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(preview, in: CGRect(origin: .zero, size: rect.size))
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

    // MARK: - 工具条

    @MainActor
    private static func drawToolbar(
        _ slots: [ToolbarSlot],
        hovered: ToolbarItem?,
        annotation: AnnotationState
    ) {
        guard !slots.isEmpty else { return }

        for row in ToolbarLayout.rowFrames(of: slots) {
            NSColor(calibratedWhite: 0.13, alpha: 0.96).setFill()
            let path = NSBezierPath(roundedRect: row, xRadius: 8, yRadius: 8)
            path.fill()
            NSColor.white.withAlphaComponent(0.14).setStroke()
            path.lineWidth = 1
            path.stroke()
        }

        for slot in slots {
            let isSelected = isSelected(slot.item, annotation: annotation)
            let isHovered = hovered == slot.item

            if isSelected || isHovered {
                let alpha: CGFloat = isSelected ? 0.9 : 0.5
                NSColor.controlAccentColor.withAlphaComponent(alpha).setFill()
                NSBezierPath(
                    roundedRect: slot.frame.insetBy(dx: 2.5, dy: 3.5),
                    xRadius: 5, yRadius: 5
                ).fill()
            }

            draw(slot, annotation: annotation)
        }
    }

    @MainActor
    private static func isSelected(_ item: ToolbarItem, annotation: AnnotationState) -> Bool {
        switch item {
        case .tool(let tool): return annotation.tool == tool
        case .color(let index): return annotation.colorIndex == index
        case .width(let index): return annotation.widthIndex == index
        case .undo, .separator, .action: return false
        }
    }

    @MainActor
    private static func draw(_ slot: ToolbarSlot, annotation: AnnotationState) {
        let frame = slot.frame

        switch slot.item {
        case .separator:
            NSColor.white.withAlphaComponent(0.18).setFill()
            NSRect(x: frame.midX - 0.5, y: frame.minY + 9, width: 1, height: frame.height - 18).fill()

        case .tool(let tool):
            let symbol = tool?.symbolName ?? "cursorarrow"
            drawCenteredSymbol(symbol, in: frame, pointSize: 14)

        case .undo:
            drawCenteredSymbol("arrow.uturn.backward", in: frame, pointSize: 13)

        case .color(let index):
            let color = AnnotationState.palette[index]
            NSColor(srgbRed: color.r, green: color.g, blue: color.b, alpha: 1).setFill()
            let dot = NSRect(x: frame.midX - 6, y: frame.midY - 6, width: 12, height: 12)
            NSBezierPath(ovalIn: dot).fill()
            NSColor.black.withAlphaComponent(0.35).setStroke()
            let ring = NSBezierPath(ovalIn: dot)
            ring.lineWidth = 1
            ring.stroke()

        case .width(let index):
            let radius = CGFloat(AnnotationState.widths[index]) / 2 + 1.5
            NSColor.white.setFill()
            NSBezierPath(ovalIn: NSRect(
                x: frame.midX - radius,
                y: frame.midY - radius,
                width: radius * 2,
                height: radius * 2
            )).fill()

        case .action(let action):
            drawSymbol(
                action.symbolName,
                at: CGPoint(x: frame.minX + ToolbarLayout.horizontalPadding, y: frame.midY),
                pointSize: ToolbarLayout.iconSize
            )
            let attrs: [NSAttributedString.Key: Any] = [
                .font: ToolbarLayout.labelFont,
                .foregroundColor: NSColor.white
            ]
            let title = action.title as NSString
            let size = title.size(withAttributes: attrs)
            title.draw(
                at: NSPoint(
                    x: frame.minX + ToolbarLayout.horizontalPadding
                        + ToolbarLayout.iconSize + ToolbarLayout.iconGap,
                    y: frame.midY - size.height / 2
                ),
                withAttributes: attrs
            )
        }
    }

    private static func drawCenteredSymbol(_ name: String, in frame: CGRect, pointSize: CGFloat) {
        guard let icon = symbolImage(name, pointSize: pointSize, tint: .white) else { return }
        icon.draw(in: CGRect(
            x: frame.midX - icon.size.width / 2,
            y: frame.midY - icon.size.height / 2,
            width: icon.size.width,
            height: icon.size.height
        ))
    }

    private static func drawSymbol(_ name: String, at leftCenter: CGPoint, pointSize: CGFloat) {
        guard let icon = symbolImage(name, pointSize: pointSize, tint: .white) else { return }
        icon.draw(in: CGRect(
            x: leftCenter.x,
            y: leftCenter.y - icon.size.height / 2,
            width: icon.size.width,
            height: icon.size.height
        ))
    }

    private static func symbolImage(_ name: String, pointSize: CGFloat, tint: NSColor) -> NSImage? {
        guard
            let base = NSImage(systemSymbolName: name, accessibilityDescription: nil),
            let sized = base.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
            )
        else { return nil }

        let image = NSImage(size: sized.size)
        image.lockFocus()
        sized.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
        tint.set()
        NSRect(origin: .zero, size: sized.size).fill(using: .sourceAtop)
        image.unlockFocus()
        return image
    }
}
