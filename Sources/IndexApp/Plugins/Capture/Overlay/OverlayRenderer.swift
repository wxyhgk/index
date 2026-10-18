import AppKit

/// 选区覆盖层的全部绘制逻辑。无状态 —— 输入模型，输出像素。
///
/// 约束：`enum` + 仅 `static func`，不持有任何可变状态（无 stored properties、
/// 无单例缓存）。所有输入（`SelectionModel`、`AnnotationState`、`slots`、
/// `hoveredControlID`、放大镜采样等）都由调用方当帧传入；绘制只读，不写回。
/// 若需缓存，放在调用方或 `MagnifierRenderer`/`AnnotationRenderer` 内部的
/// 纯函数缓存里，不在 `OverlayRenderer` 自身保留。
/// 覆盖层一帧的全部输入。宿主（`OverlayView`）每帧装配一份，渲染器只读。
///
/// 此前 `draw` 有 19 个平铺参数，调用点读起来像配置清单；聚合成结构体后
/// 「一帧画什么」变成一个可传递、可断言的值。
@MainActor
struct OverlayRenderState {
    let model: SelectionModel
    let annotation: AnnotationState
    let slots: [ToolbarSlot]
    let toolbarContext: ToolbarContext
    let toolbarOpacity: CGFloat
    let hoveredControlID: String?
    let pressedControlID: String?
    let focusedControlID: String?
    let selectionAIIsActive: Bool
    let selectionAIRect: CGRect?
    let selectionAITaskSlots: [OverlaySelectionAITaskSlot]
    let hoveredSelectionAITask: SelectionAITaskKind?
    let pressedSelectionAITask: SelectionAITaskKind?
    let selectionAIStatus: OverlaySelectionAIExecutionStatus
    let selectionAIResult: OverlaySelectionAIResultRenderState?
    let isPrimaryScreen: Bool
    let confirmHint: String?
    let fullWindowHint: Bool
    let magnifier: (sample: PixelSample, cursor: CGPoint)?
    /// 控制点淡入动画进度（0 = 不可见，1 = 完全可见）。
    let handleAlpha: CGFloat
    /// 当前 hover 的 resize handle（hover 放大反馈）。nil = 无。
    let hoveredHandle: SelectionModel.Handle?
    /// 当前 hover 的圆角控制点（hover 放大反馈）。nil = 无。
    let hoveredCorner: SelectionModel.Corner?
    /// 鼠标是否在选区内（决定四角绿点显不显示）。
    let pointerInsideSelection: Bool
}

enum OverlayRenderer {

    // MARK: - 多边形渲染

    @MainActor
    private static func drawPolygonVertexDots(
        model: SelectionModel, ctx: CGContext
    ) {
        guard let points = model.polygon?.points, !points.isEmpty else { return }
        let snapToFirst = model.polygon?.snapToFirst == true
        ctx.saveGState()
        for (i, point) in points.enumerated() {
            let lp = toLocal(CGRect(origin: point, size: .zero), in: model).origin
            if i == 0 && snapToFirst {
                let dot = CGRect(x: lp.x - 6, y: lp.y - 6, width: 12, height: 12)
                ctx.setFillColor(NSColor.systemGreen.cgColor)
                ctx.fillEllipse(in: dot)
                ctx.setStrokeColor(NSColor.white.cgColor)
                ctx.setLineWidth(2)
                ctx.strokeEllipse(in: dot)
            } else {
                let dot = CGRect(x: lp.x - 4, y: lp.y - 4, width: 8, height: 8)
                ctx.setFillColor(NSColor.white.cgColor)
                ctx.fillEllipse(in: dot)
                ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.5).cgColor)
                ctx.setLineWidth(1)
                ctx.strokeEllipse(in: dot)
            }
        }
        ctx.restoreGState()
    }

    @MainActor
    private static func drawPolygonPreviewLine(
        model: SelectionModel, ctx: CGContext
    ) {
        guard model.isPolygonMode,
              let start = model.polygonPreviewStart,
              let preview = model.polygon?.previewPoint else { return }
        let startLocal = toLocal(CGRect(origin: start, size: .zero), in: model).origin
        let previewLocal = toLocal(CGRect(origin: preview, size: .zero), in: model).origin
        ctx.saveGState()
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.7).cgColor)
        ctx.setLineWidth(1.5)
        ctx.setLineDash(phase: 0, lengths: [4, 3])
        ctx.move(to: startLocal)
        ctx.addLine(to: previewLocal)
        ctx.strokePath()
        ctx.restoreGState()
    }

    @MainActor
    private static func drawPolygonHandles(
        model: SelectionModel, ctx: CGContext
    ) {
        guard model.showsPolygonVertices, let polygon = model.confirmedPolygon else { return }
        let adjustingIndex = model.adjustingPolygonVertex
        ctx.saveGState()
        for (i, point) in polygon.enumerated() {
            let lp = toLocal(CGRect(origin: point, size: .zero), in: model).origin
            let outerR: CGFloat = adjustingIndex == i ? 10 : 7
            let innerR: CGFloat = 4
            ctx.setFillColor(NSColor.white.withAlphaComponent(0.3).cgColor)
            ctx.fillEllipse(in: CGRect(x: lp.x - outerR, y: lp.y - outerR, width: outerR * 2, height: outerR * 2))
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fillEllipse(in: CGRect(x: lp.x - innerR, y: lp.y - innerR, width: innerR * 2, height: innerR * 2))
        }
        ctx.restoreGState()
    }

    @MainActor
    static func draw(
        state: OverlayRenderState,
        in bounds: CGRect,
        ctx: CGContext
    ) {
        let model = state.model
        let annotation = state.annotation
        let slots = state.slots
        let toolbarContext = state.toolbarContext
        let hoveredControlID = state.hoveredControlID
        let pressedControlID = state.pressedControlID
        let focusedControlID = state.focusedControlID
        let selectionAIIsActive = state.selectionAIIsActive
        let selectionAIRect = state.selectionAIRect
        let selectionAITaskSlots = state.selectionAITaskSlots
        let hoveredSelectionAITask = state.hoveredSelectionAITask
        let pressedSelectionAITask = state.pressedSelectionAITask
        let selectionAIStatus = state.selectionAIStatus
        let selectionAIResult = state.selectionAIResult
        let isPrimaryScreen = state.isPrimaryScreen
        let confirmHint = state.confirmHint
        let fullWindowHint = state.fullWindowHint
        let magnifier = state.magnifier
        let handleAlpha = state.handleAlpha
        let hoveredHandle = state.hoveredHandle
        let hoveredCorner = state.hoveredCorner
        let pointerInsideSelection = state.pointerInsideSelection
        // 冻结画面本身由 CALayer 承载，这里**绝不重画位图** ——
        // 拖拽时每帧重采样一张 4K 位图会直接把主线程压垮。
        // 压暗：全屏填充 + clip 挖掉选区内部。
        // 不用 NSBezierPath evenOdd（多子路径下 fill 行为不可靠）。
        let globalRect = model.activeRect.flatMap { $0.isEmpty ? nil : $0 }
        let local = globalRect.map { toLocal($0, in: model) }
        let dimPolygon = model.polygon?.points ?? model.confirmedPolygon

        ctx.setFillColor(NSColor.black.withAlphaComponent(0.42).cgColor)
        if let dimPolygon, dimPolygon.count >= 2 {
            ctx.fill(CGRect(origin: .zero, size: bounds.size))
            ctx.saveGState()
            let cgPath = CGMutablePath()
            for (i, point) in dimPolygon.enumerated() {
                let lp = toLocal(CGRect(origin: point, size: .zero), in: model).origin
                if i == 0 { cgPath.move(to: lp) } else { cgPath.addLine(to: lp) }
            }
            if !model.isPolygonMode, dimPolygon.count >= 3 { cgPath.closeSubpath() }
            ctx.addPath(cgPath)
            ctx.clip()
            ctx.clear(CGRect(origin: .zero, size: bounds.size))
            ctx.restoreGState()
        } else if let local, !model.isPolygonMode {
            ctx.fill(CGRect(origin: .zero, size: bounds.size))
            ctx.saveGState()
            ctx.addRect(local)
            ctx.clip()
            ctx.clear(CGRect(origin: .zero, size: bounds.size))
            ctx.restoreGState()
        } else {
            ctx.fill(CGRect(origin: .zero, size: bounds.size))
        }

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
        drawAnnotations(annotation, clippedTo: local, in: bounds, baseImage: model.snapshot.image, canvasSize: bounds.size, ctx: ctx)

        if let selectionAIRect {
            drawSelectionAI(in: selectionAIRect, ctx: ctx)
        }

        let isWindowHint = model.isWindowHint
        // 悬停窗口时按住 ⌥ = 整窗捕获（不含遮挡）：紫框区分于普通的蓝框窗口选择。
        let isFullWindow = isWindowHint && fullWindowHint
        let isDragging = model.phase == .dragging
        let frameColor: NSColor = isFullWindow ? .systemPurple : (isWindowHint ? .systemBlue : .white)
        let lineWidth: CGFloat = isWindowHint ? 3 : 1.5

        // 用户画的选区：圆角 + 外发光（亮色背景上可辨）；悬停窗口提示保持直角。
        let frame = isWindowHint
            ? local.insetBy(dx: -0.75, dy: -0.75)
            : local.insetBy(dx: -0.5, dy: -0.5)
        let frameCornerRadius: CGFloat = isWindowHint ? 0 : model.cornerRadius
        let polygon = model.polygon?.points ?? model.confirmedPolygon
        let framePath: CGPath
        if let polygon {
            let path = CGMutablePath()
            for (i, point) in polygon.enumerated() {
                let lp = toLocal(CGRect(origin: point, size: .zero), in: model).origin
                if i == 0 { path.move(to: lp) } else { path.addLine(to: lp) }
            }
            if !model.isPolygonMode, polygon.count >= 3 { path.closeSubpath() }
            framePath = path
        } else {
            framePath = frameCornerRadius > 0
                ? CGPath(roundedRect: frame, cornerWidth: frameCornerRadius, cornerHeight: frameCornerRadius, transform: nil)
                : CGPath(rect: frame, transform: nil)
        }

        ctx.saveGState()
        if !isWindowHint {
            ctx.setShadow(offset: .zero, blur: 4, color: NSColor.black.withAlphaComponent(0.45).cgColor)
        }
        // 拖拽中虚线（区分"正在画"和"已确认"），松手后切实线。
        if isDragging {
            ctx.setLineDash(phase: 0, lengths: [6, 4])
        }
        ctx.addPath(framePath)
        ctx.setStrokeColor(frameColor.cgColor)
        ctx.setLineWidth(lineWidth)
        ctx.strokePath()
        ctx.restoreGState()

        drawPolygonVertexDots(model: model, ctx: ctx)
        drawPolygonPreviewLine(model: model, ctx: ctx)
        drawPolygonHandles(model: model, ctx: ctx)

        // 窗口吸附参考线（红色细线贯穿全屏）。
        if !model.isInactive {
            drawGuides(model.guides, in: bounds, model: model)
            drawSizeLabel(
                for: globalRect,
                near: local,
                ownerName: isWindowHint ? model.hoveredWindow?.ownerName : nil,
                isFullWindow: isFullWindow,
                scale: model.snapshot.scale,
                in: bounds
            )
        }

        // 有标注工具在手时隐藏控制点，避免和画布上的操作混淆。
        // 中性态和鼠标模式都显示 —— 两种状态下拖空白处仍是调整选区。
        if model.showsHandles && annotation.tool == nil && !selectionAIIsActive && !model.isInactive {
            drawHandles(in: local, alpha: handleAlpha, hovered: hoveredHandle)
            drawCornerControls(
                in: local,
                radius: model.cornerRadius,
                alpha: handleAlpha,
                hovered: hoveredCorner,
                adjusting: model.adjustingCorner,
                visible: pointerInsideSelection || model.adjustingCorner != nil
            )
        }

        if model.phase == .confirmed && !model.isInactive {
            // 工具条半透明：鼠标不在工具条上时降低 opacity（PixPin Mouse Penetration 效果）。
            ctx.saveGState()
            ctx.setAlpha(state.toolbarOpacity)
            // 用宿主传来的 context 绘制 —— 「选字」等控件的选中态取自宿主状态，
            // 这里若自己拼一个 context 就永远画不出高亮。
            ToolbarRenderer.draw(
                slots,
                hovered: hoveredControlID,
                pressed: pressedControlID,
                focused: focusedControlID,
                context: toolbarContext
            )
            ctx.restoreGState()
            // plain 模式没有工具条，用一行提示告诉用户怎么确认。
            if let confirmHint {
                drawConfirmHint(confirmHint, near: local, in: bounds)
            }

            OverlaySelectionAITaskPalette.draw(
                slots: selectionAITaskSlots,
                hovered: hoveredSelectionAITask,
                pressed: pressedSelectionAITask,
                status: selectionAIStatus
            )

            if let selectionAIResult {
                OverlaySelectionAIResultPanel.draw(
                    document: selectionAIResult.document,
                    layout: selectionAIResult.layout,
                    hovered: selectionAIResult.hovered,
                    pressed: selectionAIResult.pressed,
                    copied: selectionAIResult.copied
                )
            }
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
        baseImage: CGImage? = nil,
        canvasSize: CGSize = .zero,
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
            baseImage: baseImage,
            canvasSize: canvasSize,
            in: ctx
        )
        AnnotationRenderer.drawSelectionHint(
            selectedID: annotation.selectedID,
            layers: layers,
            strokeScale: CGFloat(annotation.strokeScale),
            in: ctx
        )
        AnnotationRenderer.drawAlignmentGuides(
            annotation.alignmentGuides,
            strokeScale: CGFloat(annotation.strokeScale),
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

    private static func drawSelectionAI(in rect: CGRect, ctx: CGContext) {
        guard rect.width > 0, rect.height > 0 else { return }
        ctx.saveGState()
        ctx.setFillColor(NSColor.systemBlue.withAlphaComponent(0.12).cgColor)
        ctx.fill(rect)
        ctx.setStrokeColor(NSColor.systemBlue.cgColor)
        ctx.setLineWidth(2)
        ctx.setLineDash(phase: 0, lengths: [6, 4])
        ctx.stroke(rect.insetBy(dx: 1, dy: 1))
        ctx.restoreGState()
    }

    private static func drawHint(in bounds: CGRect) {
        let text = "拖拽选区 · 单击窗口 · ⌥ 单击完整窗口 · ESC 取消"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: DS.font15, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.85)
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        (text as NSString).draw(
            at: NSPoint(x: (bounds.width - size.width) / 2, y: bounds.height * 0.62),
            withAttributes: attrs
        )
    }

    /// 选区下方的确认提示（plain 模式代替工具条）。放不下就挪到选区上方。
    private static func drawConfirmHint(_ text: String, near local: CGRect, in bounds: CGRect) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: DS.font12, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let textSize = (text as NSString).size(withAttributes: attrs)
        let padding: CGFloat = 8
        var box = NSRect(
            x: local.midX - (textSize.width + padding * 2) / 2,
            y: local.minY - textSize.height - padding - 8,
            width: textSize.width + padding * 2,
            height: textSize.height + padding
        )
        if box.minY < bounds.minY { box.origin.y = local.maxY + 34 }
        box.origin.x = min(max(4, box.origin.x), bounds.maxX - box.width - 4)

        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5).fill()
        (text as NSString).draw(
            at: NSPoint(x: box.minX + padding, y: box.minY + padding / 2),
            withAttributes: attrs
        )
    }

    private static func drawSizeLabel(
        for globalRect: CGRect,
        near local: CGRect,
        ownerName: String?,
        isFullWindow: Bool,
        scale: CGFloat,
        in bounds: CGRect
    ) {
        var text = "\(Int(globalRect.width * scale)) × \(Int(globalRect.height * scale))"
        if let ownerName {
            text = "\(ownerName)  \(text)"
        }
        if isFullWindow {
            text += " · 完整窗口"
        }

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: DS.font12, weight: .medium),
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

    /// 8 个调整控制点。圆点 + 外圈（比方块更精致）；选区太小时只画四角。
    /// alpha 控制淡入进度（0 = 不可见，1 = 完全可见）；hovered 控制点放大。
    private static func drawHandles(in local: CGRect, alpha: CGFloat, hovered: SelectionModel.Handle?) {
        guard alpha > 0 else { return }
        let dotSize: CGFloat = 4
        let ringSize: CGFloat = 9
        let hoveredDotSize: CGFloat = 5.5
        let hoveredRingSize: CGFloat = 12
        let cornersOnly = local.width < 40 || local.height < 40

        let handles: [SelectionModel.Handle] = cornersOnly
            ? [.topLeft, .topRight, .bottomRight, .bottomLeft]
            : SelectionModel.Handle.resizeHandles

        for handle in handles {
            let center = handle.point(in: local)
            let isHovered = (handle == hovered)
            let dot = isHovered ? hoveredDotSize : dotSize
            let ring = isHovered ? hoveredRingSize : ringSize
            // 外圈（半透明环，hover 时更亮）
            let ringRect = CGRect(
                x: center.x - ring / 2,
                y: center.y - ring / 2,
                width: ring,
                height: ring
            )
            NSColor.white.withAlphaComponent((isHovered ? 0.4 : 0.25) * alpha).setFill()
            NSBezierPath(ovalIn: ringRect).fill()
            // 实心圆点 + 细描边（压暗画面上清晰）
            let dotRect = CGRect(
                x: center.x - dot / 2,
                y: center.y - dot / 2,
                width: dot,
                height: dot
            )
            let dotPath = NSBezierPath(ovalIn: dotRect)
            NSColor.white.withAlphaComponent(alpha).setFill()
            dotPath.fill()
            NSColor.black.withAlphaComponent(0.35 * alpha).setStroke()
            dotPath.lineWidth = 0.5
            dotPath.stroke()
        }
    }

    /// 圆角绿点：鼠标进入选区后，四角各出现一个绿色小点；拖任意一点调统一半径。
    private static func drawCornerControls(
        in local: CGRect,
        radius: CGFloat,
        alpha: CGFloat,
        hovered: SelectionModel.Corner?,
        adjusting: SelectionModel.Corner?,
        visible: Bool
    ) {
        guard alpha > 0, visible, local.width >= 40, local.height >= 40 else { return }

        let inset = min(12, max(6, min(local.width, local.height) / 4))
        let active = adjusting ?? hovered

        for corner in SelectionModel.Corner.allCases {
            let center = cornerPoint(for: corner, in: local, inset: inset)
            let isHovered = (corner == hovered) || (corner == adjusting)
            let size: CGFloat = isHovered ? 11 : 8
            let dot = NSBezierPath(ovalIn: CGRect(
                x: center.x - size / 2,
                y: center.y - size / 2,
                width: size,
                height: size
            ))
            NSColor.systemGreen.withAlphaComponent((isHovered ? 1.0 : 0.85) * alpha).setFill()
            dot.fill()
            // 半透明白描边：浅色/深色截图上都能辨出边界，同时仍是「绿点」。
            NSColor.white.withAlphaComponent(0.9 * alpha).setStroke()
            dot.lineWidth = 1
            dot.stroke()
        }

        if let active, local.width >= 120, radius > 0 || adjusting != nil {
            let center = cornerPoint(for: active, in: local, inset: inset)
            drawRadiusLabel(radius: radius, near: center, in: local, alpha: alpha)
        }
    }

    private static func cornerPoint(
        for corner: SelectionModel.Corner,
        in local: CGRect,
        inset: CGFloat
    ) -> CGPoint {
        switch corner {
        case .topLeft:     return CGPoint(x: local.minX + inset, y: local.maxY - inset)
        case .topRight:    return CGPoint(x: local.maxX - inset, y: local.maxY - inset)
        case .bottomLeft:  return CGPoint(x: local.minX + inset, y: local.minY + inset)
        case .bottomRight: return CGPoint(x: local.maxX - inset, y: local.minY + inset)
        }
    }

    private static func drawRadiusLabel(radius: CGFloat, near center: CGPoint, in local: CGRect, alpha: CGFloat) {
        let text = "圆角 \(Int(radius.rounded()))"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: DS.font11, weight: .medium),
            .foregroundColor: NSColor.black.withAlphaComponent(0.85 * alpha)
        ]
        let textSize = (text as NSString).size(withAttributes: attrs)
        let padding: CGFloat = 5
        var box = NSRect(
            x: center.x + 14,
            y: center.y - (textSize.height + padding) / 2,
            width: textSize.width + padding * 2,
            height: textSize.height + padding
        )
        if box.maxX > local.maxX - 4 { box.origin.x = center.x - box.width - 14 }
        box.origin.x = max(local.minX + 4, box.origin.x)
        box.origin.y = min(max(local.minY + 4, box.origin.y), local.maxY - box.height - 4)

        NSColor.white.withAlphaComponent(0.78 * alpha).setFill()
        NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5).fill()
        (text as NSString).draw(
            at: NSPoint(x: box.minX + padding, y: box.minY + padding / 2),
            withAttributes: attrs
        )
    }

    /// 窗口吸附参考线：红色细线贯穿全屏（和标注对齐线同款视觉）。
    @MainActor
    private static func drawGuides(_ guides: [SelectionModel.SelectionGuide], in bounds: CGRect, model: SelectionModel) {
        guard !guides.isEmpty else { return }
        NSColor.systemRed.withAlphaComponent(0.8).setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1
        for guide in guides {
            if guide.isHorizontal {
                let y = guide.position - model.bounds.origin.y
                path.move(to: NSPoint(x: 0, y: y))
                path.line(to: NSPoint(x: bounds.width, y: y))
            } else {
                let x = guide.position - model.bounds.origin.x
                path.move(to: NSPoint(x: x, y: 0))
                path.line(to: NSPoint(x: x, y: bounds.height))
            }
        }
        path.stroke()
    }
}
