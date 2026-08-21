import CoreGraphics

/// 截图覆盖层与 Selection AI 像素空间之间的单次坐标变换。
/// 会话只保存裁剪图内的像素矩形，不依赖显示器在桌面中的排列位置。
struct OverlaySelectionAITransform {
    let snapshotFrame: CGRect
    let scale: CGFloat
    let cropPixelRect: CGRect

    init?(snapshot: DisplaySnapshot, confirmedRect: CGRect) {
        guard snapshot.scale > 0 else { return nil }
        let imageBounds = CGRect(
            x: 0,
            y: 0,
            width: snapshot.image.width,
            height: snapshot.image.height
        )
        let crop = snapshot.pixelRect(forGlobal: confirmedRect).integral.intersection(imageBounds)
        guard SelectionAIGeometry.isUsableBounds(crop) else { return nil }
        snapshotFrame = snapshot.frame
        scale = snapshot.scale
        cropPixelRect = crop
    }

    var imageBounds: CGRect {
        CGRect(origin: .zero, size: cropPixelRect.size)
    }

    func imagePoint(fromGlobal point: CGPoint) -> CGPoint {
        let fullPixel = CGPoint(
            x: (point.x - snapshotFrame.minX) * scale,
            y: (snapshotFrame.maxY - point.y) * scale
        )
        return CGPoint(
            x: fullPixel.x - cropPixelRect.minX,
            y: fullPixel.y - cropPixelRect.minY
        )
    }

    func viewRect(fromImage rect: CGRect, geometry: OverlayGeometry) -> CGRect {
        let fullPixel = rect.offsetBy(dx: cropPixelRect.minX, dy: cropPixelRect.minY)
        let global = CGRect(
            x: snapshotFrame.minX + fullPixel.minX / scale,
            y: snapshotFrame.maxY - fullPixel.maxY / scale,
            width: fullPixel.width / scale,
            height: fullPixel.height / scale
        )
        return geometry.viewLocal(fromGlobal: global)
    }
}

/// Capture Overlay 的薄适配：持有共享会话并完成坐标翻译，不处理 Provider、
/// 任务菜单或结果面板。
@MainActor
final class OverlaySelectionAIHost {
    let session: SelectionAISession

    init() {
        session = SelectionAISession()
    }

    init(session: SelectionAISession) {
        self.session = session
    }

    var isActive: Bool { session.snapshot.isActive }
    var isDragging: Bool { session.snapshot.phase == .dragging }

    func activate() { session.activate() }
    func deactivate() { session.deactivate() }

    @discardableResult
    func stepBack() -> Bool { session.stepBack() }

    @discardableResult
    func begin(globalPoint: CGPoint, transform: OverlaySelectionAITransform) -> Bool {
        session.begin(
            at: transform.imagePoint(fromGlobal: globalPoint),
            within: transform.imageBounds
        )
    }

    @discardableResult
    func update(globalPoint: CGPoint, transform: OverlaySelectionAITransform) -> Bool {
        session.update(
            to: transform.imagePoint(fromGlobal: globalPoint),
            within: transform.imageBounds
        )
    }

    @discardableResult
    func end(globalPoint: CGPoint, transform: OverlaySelectionAITransform) -> CGRect? {
        session.end(
            at: transform.imagePoint(fromGlobal: globalPoint),
            within: transform.imageBounds
        )
    }

    func viewSelectionRect(transform: OverlaySelectionAITransform, geometry: OverlayGeometry) -> CGRect? {
        guard let rect = session.snapshot.selectionRect, !rect.isEmpty else { return nil }
        return transform.viewRect(fromImage: rect, geometry: geometry)
    }
}

extension OverlayView {
    var selectionAITransform: OverlaySelectionAITransform? {
        guard let confirmedRect = model.confirmedRect else { return nil }
        return OverlaySelectionAITransform(snapshot: model.snapshot, confirmedRect: confirmedRect)
    }

    var selectionAIViewRect: CGRect? {
        guard let transform = selectionAITransform else { return nil }
        return selectionAIHost.viewSelectionRect(transform: transform, geometry: geometry)
    }

    var selectionAITaskSlots: [OverlaySelectionAITaskSlot] {
        guard selectionAIHost.session.snapshot.phase == .selected,
              let selectionAIViewRect
        else { return [] }
        return OverlaySelectionAITaskPalette.slots(near: selectionAIViewRect, in: bounds)
    }

    var selectionAIResultDocument: SelectionAIResultDocument? {
        guard case let .completed(response) = selectionAIExecution.status else { return nil }
        return response.document
    }

    var selectionAIResultLayout: OverlaySelectionAIResultLayout? {
        guard let document = selectionAIResultDocument,
              let selectionAIViewRect
        else { return nil }
        return OverlaySelectionAIResultPanel.layout(
            document: document,
            near: selectionAIViewRect,
            in: bounds
        )
    }

    var selectionAIResultRenderState: OverlaySelectionAIResultRenderState? {
        guard let document = selectionAIResultDocument,
              let layout = selectionAIResultLayout
        else { return nil }
        return OverlaySelectionAIResultRenderState(
            document: document,
            layout: layout,
            hovered: interactionState.hoveredSelectionAIResultAction,
            pressed: interactionState.pressedSelectionAIResultAction,
            copied: interactionState.copiedSelectionAIFormat
        )
    }

    func activateSelectionAI() {
        selectionAIExecution.reset()
        interactionState.hoveredSelectionAITask = nil
        interactionState.pressedSelectionAITask = nil
        resetSelectionAIResultInteraction()
        selectionAIHost.activate()
    }

    func deactivateSelectionAI() {
        selectionAIExecution.reset()
        interactionState.hoveredSelectionAITask = nil
        interactionState.pressedSelectionAITask = nil
        resetSelectionAIResultInteraction()
        selectionAIHost.deactivate()
    }

    @discardableResult
    func beginSelectionAI(atViewLocal point: CGPoint) -> Bool {
        guard selectionAIHost.isActive, let transform = selectionAITransform else { return false }
        let began = selectionAIHost.begin(
            globalPoint: geometry.global(fromViewLocal: point),
            transform: transform
        )
        if began {
            selectionAIExecution.reset()
            interactionState.hoveredSelectionAITask = nil
            interactionState.pressedSelectionAITask = nil
            resetSelectionAIResultInteraction()
        }
        return began
    }

    @discardableResult
    func updateSelectionAI(atViewLocal point: CGPoint) -> Bool {
        guard let transform = selectionAITransform else { return false }
        return selectionAIHost.update(
            globalPoint: geometry.global(fromViewLocal: point),
            transform: transform
        )
    }

    @discardableResult
    func endSelectionAI(atViewLocal point: CGPoint) -> CGRect? {
        guard let transform = selectionAITransform else {
            selectionAIHost.deactivate()
            return nil
        }
        return selectionAIHost.end(
            globalPoint: geometry.global(fromViewLocal: point),
            transform: transform
        )
    }

    func teardownSelectionAI() {
        deactivateSelectionAI()
    }

    @discardableResult
    func stepBackSelectionAI() -> Bool {
        guard selectionAIHost.stepBack() else { return false }
        selectionAIExecution.reset()
        resetSelectionAIResultInteraction()
        return true
    }

    func performSelectionAITask(_ kind: SelectionAITaskKind) {
        guard !selectionAIExecution.isRunning,
              let selectionRect = selectionAIHost.session.snapshot.selectionRect,
              let transform = selectionAITransform,
              let input = OverlaySelectionAIInputBuilder.makeInput(
                  model: model,
                  annotation: annotation,
                  geometry: geometry,
                  transform: transform,
                  selectionRect: selectionRect
              )
        else {
            if !selectionAIExecution.isRunning {
                selectionAIExecution.reportFailure("无法生成 AI 选区像素")
            }
            return
        }
        resetSelectionAIResultInteraction()
        selectionAIExecution.submit(
            task: OverlaySelectionAITaskPalette.task(for: kind),
            input: input
        )
    }

    func performSelectionAIResultAction(_ action: OverlaySelectionAIResultAction) {
        guard let document = selectionAIResultDocument else { return }
        switch action {
        case .close:
            selectionAIExecution.reset()
            resetSelectionAIResultInteraction()
        case let .copy(format):
            guard let payload = OverlaySelectionAIResultPanel.export(for: action, in: document) else {
                return
            }
            Clipboard.copy(text: payload.text)
            interactionState.copiedSelectionAIFormat = format
        }
    }

    func resetSelectionAIResultInteraction() {
        interactionState.hoveredSelectionAIResultAction = nil
        interactionState.pressedSelectionAIResultAction = nil
        interactionState.selectionAIResultPanelConsumedMouseDown = false
        interactionState.copiedSelectionAIFormat = nil
    }
}
