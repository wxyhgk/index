import AppKit

/// 单块显示器上的覆盖层视图。只做事件翻译 —— 选区逻辑在 `SelectionModel`，
/// 标注状态在 `AnnotationState`，绘制在 `OverlayRenderer`，布局在 `ToolbarLayout`。
///
/// 视图本身分两层：
///   · 冻结画面挂在 CALayer 的 contents 上，由合成器负责，鼠标怎么动都不重画位图
///   · 压暗、选区框、控制点、工具条画在上面一层透明的 ChromeView 里，全是平色和矢量
///
/// 之前把位图直接画在 draw() 里，拖拽时每帧要重采样两遍整屏 —— 4K 屏上直接把主线程压垮。
final class OverlayView: NSView {

    var onFinish: ((SelectionResult?) -> Void)?
    var onBecameActive: ((OverlayView) -> Void)?

    let model: SelectionModel
    let annotation = AnnotationState()

    private let isPrimaryScreen: Bool
    private let imageLayer = CALayer()
    private let chrome = ChromeView()

    private var hoveredControlID: String?

    /// 光标位置（视图局部）与该处的像素采样。选区阶段才有意义。
    private var cursor: CGPoint?
    private(set) var cursorSample: PixelSample?

    /// 只在「正在挑位置」时显示：确认之后画面已经定了，放大镜只会挡住工具条。
    private var magnifierPayload: (sample: PixelSample, cursor: CGPoint)? {
        guard AppSettings.shared.showMagnifier, !model.isInactive else { return nil }
        switch model.phase {
        case .idle, .dragging, .adjusting:
            guard let cursor, let cursorSample else { return nil }
            return (cursorSample, cursor)
        case .confirmed:
            return nil
        }
    }

    var geometry: OverlayGeometry {
        OverlayGeometry(bounds: bounds, displayOrigin: model.bounds.origin)
    }

    private var toolbarContext: ToolbarContext {
        ToolbarContext(
            annotation: annotation,
            scope: .capture,
            perform: { [weak self] actionID in self?.emit(actionID) }
        )
    }

    /// 工具条布局按需计算：绘制和命中测试用的是同一份结果，不可能不一致。
    private var slots: [ToolbarSlot] {
        guard model.phase == .confirmed, let rect = model.confirmedRect else { return [] }
        return ToolbarLayout.slots(in: bounds, config: .init(
            anchor: geometry.viewLocal(fromGlobal: rect),
            alignment: .trailing,
            context: toolbarContext
        ))
    }

    init(model: SelectionModel, isPrimaryScreen: Bool) {
        self.model = model
        self.isPrimaryScreen = isPrimaryScreen
        super.init(frame: .zero)

        wantsLayer = true

        imageLayer.contents = model.snapshot.image
        imageLayer.contentsGravity = .resize
        imageLayer.zPosition = -1
        // 关掉隐式动画，否则改 frame 会有淡入。
        imageLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(imageLayer)

        chrome.render = { [unowned self] ctx, bounds in
            OverlayRenderer.draw(
                model: self.model,
                annotation: self.annotation,
                slots: self.slots,
                hoveredControlID: self.hoveredControlID,
                isPrimaryScreen: self.isPrimaryScreen,
                magnifier: self.magnifierPayload,
                in: bounds,
                ctx: ctx
            )
        }
        addSubview(chrome)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    /// 覆盖层铺在每块屏上，但同一时刻只有一个窗口是 key。默认情况下点击非 key 窗口时，
    /// 第一次点击只会激活窗口、不传给视图 —— 表现就是「副屏要点两次才有反应」。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = bounds
        imageLayer.contentsScale = window?.backingScaleFactor ?? 2
        chrome.frame = bounds
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.activeAlways, .mouseMoved, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
        redrawIfNeeded(model.hover(at: NSEvent.mouseLocation))
    }

    func setInactive(_ value: Bool) {
        redrawIfNeeded(model.setInactive(value))
    }

    func redrawIfNeeded(_ changed: Bool) {
        if changed { redraw() }
    }

    func redraw() {
        chrome.needsDisplay = true
    }

    private func localPoint(of event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil)
    }

    /// 光标一动就重新采样。采的是一小块（21×21 像素）+ 单个像素，都是内存操作。
    private func updateCursor(_ local: CGPoint) {
        guard AppSettings.shared.showMagnifier else {
            if cursor != nil { cursor = nil; cursorSample = nil }
            return
        }
        cursor = local
        cursorSample = model.snapshot.sample(aroundGlobal: geometry.global(fromViewLocal: local))
    }

    // MARK: - 鼠标

    override func mouseMoved(with event: NSEvent) {
        switch model.phase {
        case .confirmed:
            let local = localPoint(of: event)
            let hit = slots.first { $0.control != nil && $0.frame.contains(local) }?.control?.id
            if hit != hoveredControlID {
                hoveredControlID = hit
                redraw()
            }
            if hit != nil {
                NSCursor.arrow.set()
            } else if annotation.tool != nil {
                NSCursor.crosshair.set()
            } else {
                cursor(for: model.handle(at: geometry.global(fromViewLocal: local))).set()
            }
        case .idle:
            NSCursor.crosshair.set()
            model.hover(at: NSEvent.mouseLocation)
            updateCursor(localPoint(of: event))
            redraw()
        case .dragging, .adjusting:
            break
        }
    }

    /// AppKit 没有公开的斜向缩放光标，四角退回十字。
    private func cursor(for handle: SelectionModel.Handle?) -> NSCursor {
        switch handle {
        case .left, .right:             return .resizeLeftRight
        case .top, .bottom:             return .resizeUpDown
        case .inside:                   return .openHand
        case .topLeft, .topRight,
             .bottomLeft, .bottomRight: return .crosshair
        case nil:                       return .crosshair
        }
    }

    override func mouseDown(with event: NSEvent) {
        let local = localPoint(of: event)

        // 工具条命中优先
        if model.phase == .confirmed,
           let control = slots.first(where: { $0.control != nil && $0.frame.contains(local) })?.control {
            control.activate(toolbarContext)
            redraw()
            return
        }

        let global = geometry.global(fromViewLocal: local)
        hoveredControlID = nil

        // 手上有标注工具时，选区内的拖拽是画标注，不是调整选区
        if model.phase == .confirmed,
           annotation.tool != nil,
           let selection = model.confirmedRect, selection.contains(global) {
            annotation.beginDraw(at: geometry.annotationPoint(fromViewLocal: local))
            redraw()
            return
        }

        // 有工具在手却点在选区外：忽略，避免误删已画的内容
        if annotation.tool != nil, model.phase == .confirmed {
            return
        }

        // 指针模式下点中已画的图层 → 选中并准备拖动；点空处 → 取消选中，
        // 落回下面的选区调整逻辑。只在选区内测试：图层出了选区的部分是看不见的。
        if model.phase == .confirmed, annotation.tool == nil,
           let selection = model.confirmedRect, selection.contains(global) {
            let canvas = geometry.annotationPoint(fromViewLocal: local)
            if let id = annotation.layer(at: canvas) {
                annotation.endTextEditing()
                annotation.beginMove(id: id, at: canvas)
                onBecameActive?(self)
                redraw()
                return
            }
            redrawIfNeeded(annotation.select(nil))
        }

        annotation.endTextEditing()

        // 点在已有选区的控制点或内部 → 调整，而不是重画
        if let handle = model.handle(at: global) {
            model.beginAdjust(handle: handle, at: global)
            if handle.isMove { NSCursor.closedHand.set() }
        } else {
            model.beginDrag(at: global)
        }

        onBecameActive?(self)
        redraw()
    }

    override func mouseDragged(with event: NSEvent) {
        let local = localPoint(of: event)
        updateCursor(local)
        if annotation.isDrawing {
            redrawIfNeeded(annotation.updateDraw(to: geometry.annotationPoint(fromViewLocal: local)))
            return
        }
        if annotation.isMoving {
            redrawIfNeeded(annotation.updateMove(to: geometry.annotationPoint(fromViewLocal: local)))
            return
        }

        let global = geometry.global(fromViewLocal: local)
        switch model.phase {
        case .adjusting:
            model.updateAdjust(to: global)
        default:
            model.updateDrag(to: global)
        }
        redraw()
    }

    override func mouseUp(with event: NSEvent) {
        if annotation.isDrawing {
            annotation.endDraw(pixelSource: frozenPixels)
            redraw()
            return
        }
        if annotation.isMoving {
            annotation.endMove(pixelSource: frozenPixels)
            redraw()
            return
        }

        switch model.phase {
        case .adjusting:
            model.endAdjust()
            hoveredControlID = nil
            NSCursor.arrow.set()
        default:
            if model.endDrag() {
                hoveredControlID = nil
                NSCursor.arrow.set()
            }
        }
        redraw()
    }

    /// 马赛克要从冻结画面取原始像素：标注空间是显示器局部左上原点，先换回 AppKit 全局。
    private func frozenPixels(_ rect: CGRect) -> CGImage? {
        let snapshot = model.snapshot
        return snapshot.crop(globalRect: CGRect(
            x: snapshot.frame.minX + rect.minX,
            y: snapshot.frame.maxY - rect.maxY,
            width: rect.width,
            height: rect.height
        ))
    }

    /// 右键逐级退出：图层选中 → 文字输入 → 标注工具 → 选区 → 整个截图流程。
    override func rightMouseDown(with event: NSEvent) {
        if annotation.select(nil) {
            redraw()
        } else if annotation.isEditingText {
            annotation.endTextEditing()
            redraw()
        } else if annotation.tool != nil {
            annotation.tool = nil
            redraw()
        } else if model.phase == .confirmed {
            model.reset()
            redraw()
        } else {
            onFinish?(nil)
        }
    }

    // MARK: - 收尾

    func cancel() {
        onFinish?(nil)
    }

    func emit(_ actionID: String) {
        guard
            model.phase == .confirmed,
            let region = model.confirmedRect,
            let image = model.makeCroppedImage()
        else { return }

        annotation.endTextEditing()
        // 画布空间（显示器局部、点）→ 图像像素。类型上强制走这一步。
        let layers = annotation.exportLayers(
            selection: geometry.annotationRect(fromGlobal: region),
            scale: model.snapshot.scale
        )

        onFinish?(SelectionResult(
            region: region,
            display: model.snapshot.display,
            window: model.confirmedWindow,
            actionID: actionID,
            image: image,
            layers: layers
        ))
    }
}
