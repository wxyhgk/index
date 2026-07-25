import AppKit

struct SelectionResult {
    /// AppKit 全局坐标。
    let region: CGRect
    let display: DisplayInfo
    /// 单击窗口选中时非空，用于元数据归因。
    let window: WindowInfo?
    let action: CaptureAction
    /// 已经从冻结画面裁好的像素 —— 到这一步不需要再截屏了。
    let image: CGImage
    /// 截图时画的标注，坐标已换算到裁剪图的像素空间。原图保持干净，这些作为修订入库。
    let layers: [Layer]
}

/// 覆盖所有显示器的选区层。
///
/// 只负责：建窗口、分发选区结果、协调多屏之间的互斥。
/// 具体的状态机在 `SelectionModel`，绘制在 `OverlayRenderer`，布局在 `ToolbarLayout`。
@MainActor
final class SelectionOverlayController {

    private var windows: [OverlayWindow] = []
    private var views: [OverlayView] = []
    private var completion: ((SelectionResult?) -> Void)?

    var isActive: Bool { !windows.isEmpty }

    /// - Parameter snapshots: 每块屏的冻结画面，必须在覆盖层出现**之前**拍好。
    func begin(
        snapshots: [DisplaySnapshot],
        windowList: [WindowInfo],
        completion: @escaping (SelectionResult?) -> Void
    ) {
        guard !isActive, !snapshots.isEmpty else { return }
        self.completion = completion

        let primaryID = NSScreen.main.flatMap(Geometry.displayID(of:))

        for snapshot in snapshots {
            guard let screen = NSScreen.screens.first(where: {
                Geometry.displayID(of: $0) == snapshot.display.id
            }) else { continue }

            let model = SelectionModel(snapshot: snapshot, windows: windowList)
            let view = OverlayView(model: model, isPrimaryScreen: snapshot.display.id == primaryID)
            view.onFinish = { [weak self] result in self?.finish(result) }
            view.onBecameActive = { [weak self] owner in
                // 一次只允许一块屏处于活动状态。
                self?.views.forEach { $0.setInactive($0 !== owner) }
            }

            let window = OverlayWindow(screen: screen)
            window.contentView = view
            window.orderFrontRegardless()
            windows.append(window)
            views.append(view)
        }

        // 鼠标当前所在的那块屏优先拿 key —— 否则键盘事件会落到别的屏上。
        let mouse = NSEvent.mouseLocation
        let preferred = windows.first { $0.frame.contains(mouse) } ?? windows.first
        preferred?.makeKeyAndOrderFront(nil)

        NSApp.activate(ignoringOtherApps: true)
        NSCursor.crosshair.push()
    }

    private func finish(_ result: SelectionResult?) {
        let handler = completion
        completion = nil
        dismiss()
        handler?(result)
    }

    func dismiss() {
        guard isActive else { return }
        NSCursor.pop()
        NSCursor.arrow.set()
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        views.removeAll()
    }
}

// MARK: - 窗口

private final class OverlayWindow: NSWindow {

    init(screen: NSScreen) {
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .screenSaver
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        setFrame(screen.frame, display: true)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}


// MARK: - 视图
//
// 分两层：
//   · 冻结画面放在 CALayer 的 contents 里，由合成器负责，鼠标怎么动都不重画位图
//   · 压暗、选区框、控制点、工具条画在上面一层透明视图里，全是平色和矢量，成本可忽略
//
// 之前把位图直接画在 draw() 里，拖拽时每帧要重采样两遍整屏 —— 4K 屏上直接把主线程压垮。

private final class OverlayView: NSView {

    var onFinish: ((SelectionResult?) -> Void)?
    var onBecameActive: ((OverlayView) -> Void)?

    private let model: SelectionModel
    private let isPrimaryScreen: Bool

    private let imageLayer = CALayer()
    private let chrome = ChromeView()
    private let annotation = AnnotationState()

    private var hoveredItem: ToolbarItem?

    /// 工具条布局按需计算：绘制和命中测试用的是同一份结果，不可能不一致。
    private var slots: [ToolbarSlot] {
        guard model.phase == .confirmed, let rect = model.confirmedRect else { return [] }
        return ToolbarLayout.slots(for: localRect(rect), in: bounds)
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
                hoveredItem: self.hoveredItem,
                isPrimaryScreen: self.isPrimaryScreen,
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

    private func redrawIfNeeded(_ changed: Bool) {
        if changed { redraw() }
    }

    private func redraw() {
        chrome.needsDisplay = true
    }

    // MARK: 坐标

    private func toGlobal(_ local: CGPoint) -> CGPoint {
        CGPoint(x: local.x + model.bounds.origin.x, y: local.y + model.bounds.origin.y)
    }

    private func localRect(_ global: CGRect) -> CGRect {
        CGRect(
            x: global.origin.x - model.bounds.origin.x,
            y: global.origin.y - model.bounds.origin.y,
            width: global.width,
            height: global.height
        )
    }

    private func localPoint(of event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil)
    }

    /// 视图局部（左下原点）→ 显示器局部左上原点。标注图层就存在这个坐标系里。
    private func annotationPoint(_ viewLocal: CGPoint) -> CGPoint {
        CGPoint(x: viewLocal.x, y: bounds.height - viewLocal.y)
    }

    private var selectionInAnnotationSpace: CGRect? {
        guard let rect = model.confirmedRect else { return nil }
        let local = localRect(rect)
        return CGRect(
            x: local.minX,
            y: bounds.height - local.maxY,
            width: local.width,
            height: local.height
        )
    }

    // MARK: 事件

    override func mouseMoved(with event: NSEvent) {
        switch model.phase {
        case .confirmed:
            let local = localPoint(of: event)
            let hit = slots.first { $0.item.isInteractive && $0.frame.contains(local) }?.item
            if hit != hoveredItem {
                hoveredItem = hit
                redraw()
            }
            if hit != nil {
                NSCursor.arrow.set()
            } else if annotation.tool != nil {
                NSCursor.crosshair.set()
            } else {
                cursor(for: model.handle(at: toGlobal(local))).set()
            }
        case .idle:
            NSCursor.crosshair.set()
            redrawIfNeeded(model.hover(at: NSEvent.mouseLocation))
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
           let slot = slots.first(where: { $0.item.isInteractive && $0.frame.contains(local) }) {
            handleToolbar(slot.item)
            return
        }

        let global = toGlobal(local)
        hoveredItem = nil

        // 手上有标注工具时，选区内的拖拽是画标注，不是调整选区
        if model.phase == .confirmed,
           annotation.tool != nil,
           let selection = model.confirmedRect, selection.contains(global) {
            annotation.beginDraw(at: annotationPoint(local))
            redraw()
            return
        }

        // 有工具在手却点在选区外：忽略，避免误删已画的内容
        if annotation.tool != nil, model.phase == .confirmed {
            return
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

    private func handleToolbar(_ item: ToolbarItem) {
        switch item {
        case .tool(let tool):
            annotation.endTextEditing()
            annotation.tool = tool
        case .color(let index):
            annotation.colorIndex = index
        case .width(let index):
            annotation.widthIndex = index
        case .undo:
            annotation.undo()
        case .action(let action):
            emit(action)
            return
        case .separator:
            return
        }
        redraw()
    }

    override func mouseDragged(with event: NSEvent) {
        let local = localPoint(of: event)
        if annotation.isDrawing {
            redrawIfNeeded(annotation.updateDraw(to: annotationPoint(local)))
            return
        }

        let global = toGlobal(local)
        switch model.phase {
        case .adjusting:
            redrawIfNeeded(model.updateAdjust(to: global))
        default:
            redrawIfNeeded(model.updateDrag(to: global))
        }
    }

    override func mouseUp(with event: NSEvent) {
        if annotation.isDrawing {
            annotation.endDraw(in: model.snapshot)
            redraw()
            return
        }

        switch model.phase {
        case .adjusting:
            model.endAdjust()
            hoveredItem = nil
            NSCursor.arrow.set()
        default:
            if model.endDrag() {
                hoveredItem = nil
                NSCursor.arrow.set()
            }
        }
        redraw()
    }

    override func rightMouseDown(with event: NSEvent) {
        if annotation.isEditingText {
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

    override func keyDown(with event: NSEvent) {
        // 正在输入文字时，除了 ESC / Return 之外的按键都送进文字图层。
        if annotation.isEditingText {
            switch event.keyCode {
            case 53, 36, 76:
                annotation.endTextEditing()
            case 51:
                annotation.deleteBackward()
            default:
                guard let text = event.characters, !text.isEmpty,
                      !event.modifierFlags.contains(.command) else { return }
                annotation.insertText(text)
            }
            redraw()
            return
        }

        let cmd = event.modifierFlags.contains(.command)
        if cmd, event.keyCode == 6 {          // ⌘Z 撤销标注
            redrawIfNeeded(annotation.undo())
            return
        }

        switch event.keyCode {
        case 53:                        // ESC
            if annotation.tool != nil {
                annotation.tool = nil
                redraw()
            } else {
                onFinish?(nil)
            }
        case 36, 76:                    // Return / 小键盘 Enter
            emit(.pin)
        case 8 where cmd:               // ⌘C
            emit(.copy)
        case 1 where cmd:               // ⌘S
            emit(.save)
        case 9:  selectTool(nil)        // V 指针
        case 15: selectTool(.rect)      // R 矩形
        case 31: selectTool(.ellipse)   // O 椭圆
        case 0:  selectTool(.arrow)     // A 箭头
        case 17: selectTool(.text)      // T 文字
        case 4:  selectTool(.highlight) // H 高亮
        case 35: selectTool(.pixelate)  // P 马赛克
        case 123, 124, 125, 126:        // ← → ↓ ↑
            nudge(keyCode: event.keyCode, modifiers: event.modifierFlags)
        default:
            super.keyDown(with: event)
        }
    }

    private func selectTool(_ tool: AnnotationTool?) {
        guard model.phase == .confirmed else { return }
        annotation.endTextEditing()
        annotation.tool = tool
        redraw()
    }

    /// 方向键微调选区：默认移动 1pt，⇧ 变 10pt，⌥ 改为拖动右上角（调尺寸）。
    private func nudge(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        let step: CGFloat = modifiers.contains(.shift) ? 10 : 1
        var dx: CGFloat = 0
        var dy: CGFloat = 0
        switch keyCode {
        case 123: dx = -step
        case 124: dx = step
        case 125: dy = -step
        case 126: dy = step
        default: return
        }
        redrawIfNeeded(model.nudge(dx: dx, dy: dy, resizing: modifiers.contains(.option)))
    }

    private func emit(_ action: CaptureAction) {
        guard
            model.phase == .confirmed,
            let region = model.confirmedRect,
            let image = model.makeCroppedImage()
        else { return }

        annotation.endTextEditing()
        let layers = selectionInAnnotationSpace.map {
            annotation.exportLayers(selection: $0, scale: model.snapshot.scale)
        } ?? []

        onFinish?(SelectionResult(
            region: region,
            display: model.snapshot.display,
            window: model.confirmedWindow,
            action: action,
            image: image,
            layers: layers
        ))
    }
}

/// 只画矢量装饰的透明层。不参与命中测试 —— 事件穿透回 OverlayView。
private final class ChromeView: NSView {

    var render: ((CGContext, CGRect) -> Void)?

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        render?(ctx, bounds)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
