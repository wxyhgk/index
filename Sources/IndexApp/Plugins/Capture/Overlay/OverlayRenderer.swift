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
}

enum OverlayRenderer {

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

        if let selectionAIRect {
            drawSelectionAI(in: selectionAIRect, ctx: ctx)
        }

        let isWindowHint = model.isWindowHint
        // 悬停窗口时按住 ⌥ = 整窗捕获（不含遮挡）：紫框区分于普通的蓝框窗口选择。
        let isFullWindow = isWindowHint && fullWindowHint
        let frameColor: NSColor = isFullWindow ? .systemPurple : (isWindowHint ? .systemBlue : .white)
        ctx.setStrokeColor(frameColor.cgColor)
        ctx.setLineWidth(isWindowHint ? 3 : 1.5)
        ctx.stroke(local.insetBy(dx: -0.75, dy: -0.75))

        drawSizeLabel(
            for: globalRect,
            near: local,
            ownerName: isWindowHint ? model.hoveredWindow?.ownerName : nil,
            isFullWindow: isFullWindow,
            scale: model.snapshot.scale,
            in: bounds
        )

        // 有标注工具在手时隐藏控制点，避免和画布上的操作混淆。
        // 中性态和鼠标模式都显示 —— 两种状态下拖空白处仍是调整选区。
        if model.showsHandles && annotation.tool == nil && !selectionAIIsActive {
            drawHandles(in: local)
        }

        if model.phase == .confirmed {
            // 用宿主传来的 context 绘制 —— 「选字」等控件的选中态取自宿主状态，
            // 这里若自己拼一个 context 就永远画不出高亮。
            ToolbarRenderer.draw(
                slots,
                hovered: hoveredControlID,
                pressed: pressedControlID,
                focused: focusedControlID,
                context: toolbarContext
            )
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
        AnnotationRenderer.drawSelectionHint(
            selectedID: annotation.selectedID,
            layers: layers,
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
            path.lineWidth = DS.hairline
            path.stroke()
        }
    }
}
