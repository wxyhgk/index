import AppKit
import VisionKit

/// 钉图的内容视图。**只装图片** —— 工具条是挂在窗口下方的独立子窗口
/// （`PinToolbarPanel`），不在这里画、也不占这里的空间。
///
/// 和截图覆盖层共用 `AnnotationState` 与同一份工具条注册表 ——
/// 所以钉完图之后工具条不换、手感不断，可以接着画。
///
/// 画布空间是**图片像素、左上原点**，标注图层直接存在这个坐标系里，
/// 和入库的修订一致，不需要再做换算。
final class PinImageView: NSView {

    var onScrollZoom: ((CGFloat) -> Void)?
    var onOpacityStep: ((CGFloat) -> Void)?
    var onAction: ((String) -> Void)?
    var onAnnotationsChanged: (() -> Void)?
    /// 工具条的内容可能变了（工具、选中、撤销栈、效果开关……）——
    /// 通知控制器重算工具条窗口的尺寸与位置并重绘。
    /// **不是**尺寸随窗口变：宽度只跟「此刻有哪些控件可见」走。
    var onToolbarInvalidated: (() -> Void)?
    /// 鼠标进出图片区。控制器把它和工具条窗口的进出合并成一个悬停状态。
    var onHoverChanged: (() -> Void)?
    /// ⌘T 切换鼠标穿透。
    var onTogglePassthrough: (() -> Void)?

    /// 穿透模式：窗口收不到鼠标，边框改虚线提示「现在点不到我」，工具条窗口也收起来。
    var isPassthrough = false {
        didSet {
            // 穿透中收不到任何鼠标事件，选字层留着只会误导。
            if isPassthrough { exitLiveText() }
            needsDisplay = true
        }
    }

    let annotation = AnnotationState()

    private let base: CGImage
    /// 截图时画的标注，只读地叠在底图上。
    private let initialLayers: Layers<ImageSpace>
    /// 底图 + 已应用的马赛克。只在马赛克图层增减时重算，绝不逐帧跑 CoreImage。
    private var canvasImage: CGImage

    /// 选字（Live Text）模式：系统 `ImageAnalysisOverlayView` 叠在图像区域上。
    /// 分析对象是 canvasImage（含已应用马赛克）—— 打了码的字不该还能选出来。
    private(set) var isLiveTextActive = false
    private var liveTextOverlay: ImageAnalysisOverlayView?
    /// 分析结果按当时的马赛克图层缓存 —— 撤销/重做增删了马赛克就过期。
    private var liveTextAnalysis: (pixelates: Layers<ImageSpace>, task: Task<ImageAnalysis?, Never>)?

    init(base: CGImage, layers: Layers<ImageSpace>) {
        self.base = base
        self.initialLayers = layers
        let pixelates = layers.filter { $0.kind == .pixelate }
        self.canvasImage = pixelates.isEmpty
            ? base
            : LayerRenderer.render(base: base, layers: pixelates)

        super.init(frame: .zero)
        wantsLayer = true
        // 效果层的注入上下文由 PinWindowController 统一设置（它有 shot 元数据）。
    }

    required init?(coder: NSCoder) { fatalError() }

    /// 钉图窗口的画布空间**就是**图片像素，所以投影是恒等变换。
    /// 仍然显式走一遍，是为了让「画布空间」和「图像空间」在类型上始终分明。
    private var newLayers: Layers<ImageSpace> {
        annotation.layers.projected(onto: .zero, scale: 1)
    }

    /// 截图时的标注 + 钉图后新加的，合起来就是当前这版的完整图层。
    var allLayers: Layers<ImageSpace> { initialLayers + newLayers }

    // MARK: - 画布换算

    /// 图片像素 → 视图点。整个视图就是图片 —— 工具条搬进独立窗口之后，
    /// 这里不再有任何「给工具条让位」的逻辑，倍率直接由窗口尺寸决定。
    private var displayScale: CGFloat {
        guard base.width > 0, bounds.width > 0 else { return 1 }
        return bounds.width / CGFloat(base.width)
    }

    private func canvasPoint(_ viewLocal: CGPoint) -> CGPoint {
        let inverse = 1 / max(displayScale, 0.0001)
        return CGPoint(
            x: viewLocal.x * inverse,
            y: (bounds.maxY - viewLocal.y) * inverse
        )
    }

    private func syncStrokeScale() {
        // 笔宽按显示倍率反算，这样不论钉图被缩放到多大，画出来的线在屏幕上都一样粗。
        annotation.strokeScale = Double(1 / max(displayScale, 0.0001))
    }

    // MARK: - 工具条

    /// 工具条窗口画什么、控件被点时读什么状态，都取自这里 ——
    /// 状态只有一份，工具条搬到别的窗口去也还是这一份。
    var toolbarContext: ToolbarContext {
        ToolbarContext(
            annotation: annotation,
            scope: .pinned,
            perform: { [weak self] actionID in self?.onAction?(actionID) },
            isLiveTextActive: { [weak self] in self?.isLiveTextActive ?? false },
            // 不支持的机型不传 toggle → 「选字」控件整个不出现。
            toggleLiveText: LiveTextAnalyzer.isSupported
                ? { [weak self] in self?.toggleLiveText() }
                : nil
        )
    }

    /// 工具条不认识具体控件，交给控件自己处理。图层数量可能因此变化，
    /// 所以统一在这里刷新画布并通知控制器落库。工具条窗口点中控件后调这里 ——
    /// 状态变更的入口只有这一个。
    func activateToolbarControl(_ control: any ToolbarControl) {
        syncStrokeScale()
        control.activate(toolbarContext)
        // 选字模式下点了别的工具（画笔 / 指针）→ 自动退出选字。
        if isLiveTextActive, control.group == .tools, control.id != LiveTextControl.controlID {
            exitLiveText()
        }
        refreshCanvas()
        needsDisplay = true
        onAnnotationsChanged?()
        onToolbarInvalidated?()
    }

    /// 图层内容变化（画完、移完、删完）后的统一收尾：重算马赛克底图、重绘、通知落库。
    /// 键盘扩展也要用，所以不是 private。
    func commitAnnotationChange() {
        refreshCanvas()
        // 选字模式中 ⌘Z 撤销 / 重做可能增删马赛克 —— 底图变了，分析跟着换
        //（缓存按马赛克图层判等，没动马赛克就是空操作）。
        if isLiveTextActive {
            prepareLiveTextAnalysis()
            applyLiveTextAnalysis()
        }
        needsDisplay = true
        onAnnotationsChanged?()
        onToolbarInvalidated?()
    }

    private func refreshCanvas() {
        let pixelates = allLayers.filter { $0.kind == .pixelate }
        canvasImage = pixelates.isEmpty
            ? base
            : LayerRenderer.render(base: base, layers: pixelates)
    }

    // MARK: - AppKit 基础

    override var acceptsFirstResponder: Bool { true }

    /// 钉图窗口经常不是 key，没有这个的话第一次点击会被吞掉。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// 自己接管拖动，AppKit 不要插手 —— 否则点工具条会被当成拖窗口。
    override var mouseDownCanMoveWindow: Bool { false }

    /// 窗口缩放会改变图片显示区，选字层跟着贴齐。
    /// 分析结果是归一化坐标，只改 frame 不用重跑。
    override func layout() {
        super.layout()
        liveTextOverlay?.frame = bounds
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved],
            owner: self,
            userInfo: nil
        ))
    }

    // MARK: - 鼠标

    override func mouseEntered(with event: NSEvent) {
        onHoverChanged?()
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChanged?()
    }

    override func mouseMoved(with event: NSEvent) {
        onHoverChanged?()
        let point = convert(event.locationInWindow, from: nil)
        if isLiveTextActive {
            // 图像区域的光标（I-beam）由系统 overlay 自己管，这里不抢。
            return
        }
        if annotation.tool == nil {
            // 指针模式：悬停到选中图层的缩放控制点时换 resize 光标。
            syncStrokeScale()
            if let handle = annotation.resizeHandle(at: canvasPoint(point)) {
                handle.cursor.set()
                return
            }
        }
        (annotation.tool != nil ? NSCursor.crosshair : NSCursor.arrow).set()
    }

    override func mouseDown(with event: NSEvent) {
        // 工具条的内容取决于工具 / 选中 / 撤销栈，这一下点击都可能改到 ——
        // 走哪条分支都要让工具条窗口重算一次。
        defer { onToolbarInvalidated?() }

        let point = convert(event.locationInWindow, from: nil)

        // 选字模式：事件全归系统 overlay（子视图铺满，命中优先），
        // 退出只走控件 / Esc / 切工具 / 右键。
        if isLiveTextActive { return }

        if annotation.tool != nil {
            syncStrokeScale()
            annotation.beginDraw(at: canvasPoint(point))
            // 序号是点击即成层的工具：不进入拖拽也不进入文字编辑态，
            // mouseUp 不会走 endDraw，所以在这里就落库。
            if !annotation.isDrawing && !annotation.isEditingText {
                commitAnnotationChange()
            } else {
                needsDisplay = true
            }
            return
        }

        // 指针模式下优先命中选中图层的缩放控制点；再是图层本体（选中并准备拖动）；
        // 点空处 → 取消选中，落回下面的拖窗口逻辑。
        // 截图时带来的底层标注是只读的，不参与命中。
        syncStrokeScale()
        let canvas = canvasPoint(point)
        if let handle = annotation.resizeHandle(at: canvas) {
            annotation.endTextEditing()
            annotation.beginResize(handle: handle, at: canvas)
            needsDisplay = true
            return
        }
        if let id = annotation.layer(at: canvas) {
            annotation.endTextEditing()
            annotation.beginMove(id: id, at: canvas)
            needsDisplay = true
            return
        }
        if annotation.select(nil) {
            needsDisplay = true
        }

        annotation.endTextEditing()

        if event.clickCount == 2 {
            onAction?(ActionID.copy)
            return
        }

        window?.performDrag(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if annotation.isDrawing {
            if annotation.updateDraw(to: canvasPoint(point)) { needsDisplay = true }
        } else if annotation.isMoving {
            if annotation.updateMove(to: canvasPoint(point)) { needsDisplay = true }
        } else if annotation.isResizing {
            if annotation.updateResize(to: canvasPoint(point)) { needsDisplay = true }
        }
    }

    override func mouseUp(with event: NSEvent) {
        // 画完 / 移完 / 缩完都可能改变可撤销状态 → 工具条内容跟着变。
        defer { onToolbarInvalidated?() }

        if annotation.isDrawing {
            annotation.endDraw { [base] rect in
                base.cropping(to: rect.integral)
            }
            commitAnnotationChange()
        } else if annotation.isMoving {
            annotation.endMove { [base] rect in
                base.cropping(to: rect.integral)
            }
            commitAnnotationChange()
        } else if annotation.isResizing {
            annotation.endResize { [base] rect in
                base.cropping(to: rect.integral)
            }
            commitAnnotationChange()
        }
    }

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            onOpacityStep?(event.scrollingDeltaY > 0 ? 0.05 : -0.05)
        } else {
            onScrollZoom?(event.scrollingDeltaY)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        defer { onToolbarInvalidated?() }

        if isLiveTextActive {
            // 图像上的右键归系统 overlay（服务菜单）；能落到这里的说明没被它接走。
            exitLiveText()
        } else if annotation.isEditingText {
            annotation.endTextEditing()
            needsDisplay = true
        } else if annotation.tool != nil {
            annotation.tool = nil
            needsDisplay = true
        } else {
            super.rightMouseDown(with: event)
        }
    }

    // MARK: - 选字（Live Text）

    /// 进模式时才跑分析（截图侧是确认选区就预跑；钉图常驻屏幕、随时可能改标注，
    /// 常态预跑浪费）。按马赛克图层缓存：没变就复用任务，变了取消重跑。
    /// 分析输入就是 canvasImage —— 打了码的字不该还能被拖选出来。
    private func prepareLiveTextAnalysis() {
        let pixelates = allLayers.filter { $0.kind == .pixelate }
        if let cached = liveTextAnalysis, cached.pixelates == pixelates { return }
        liveTextAnalysis?.task.cancel()
        let image = canvasImage
        liveTextAnalysis = (pixelates, Task { await LiveTextAnalyzer.analyze(image) })
    }

    /// 等分析任务出结果后塞进当前的系统层。任务可能是复用的（早就跑完，立即返回）。
    /// 退出/换层后迟到的结果直接丢弃。
    private func applyLiveTextAnalysis() {
        let task = liveTextAnalysis?.task
        Task { [weak self, weak overlay = liveTextOverlay] in
            let analysis = await task?.value
            guard let self, let overlay,
                  self.isLiveTextActive, overlay === self.liveTextOverlay else { return }
            overlay.analysis = analysis
        }
    }

    private func toggleLiveText() {
        isLiveTextActive ? exitLiveText() : enterLiveText()
    }

    private func enterLiveText() {
        guard !isLiveTextActive else { return }
        annotation.endTextEditing()
        annotation.select(nil)
        annotation.tool = nil
        isLiveTextActive = true
        prepareLiveTextAnalysis()

        // 系统层铺满视图。分析的是完整的 canvasImage，而视图整个就是整图等比缩放后的
        // 显示区域，归一化坐标按 bounds 映射即对齐 —— 与窗口缩放倍率、Retina 与否无关。
        let overlay = ImageAnalysisOverlayView()
        overlay.preferredInteractionTypes = [.textSelection]
        overlay.frame = bounds
        addSubview(overlay)
        liveTextOverlay = overlay
        applyLiveTextAnalysis()
        needsDisplay = true
    }

    /// 退出选字：拆掉系统层，键盘焦点收回来。键盘扩展也要用，所以不是 private。
    func exitLiveText() {
        guard isLiveTextActive else { return }
        isLiveTextActive = false
        liveTextOverlay?.removeFromSuperview()
        liveTextOverlay = nil
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    /// 选字模式下的 ⌘C：有选中文字就复制文字（而不是整张图）。返回是否已处理。
    func copyLiveTextSelection() -> Bool {
        guard let overlay = liveTextOverlay, overlay.hasActiveTextSelection else { return false }
        Clipboard.copy(text: overlay.selectedText)
        return true
    }

    // MARK: - 绘制

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let frame = bounds
        guard frame.height > 1 else { return }

        let clip = NSBezierPath(roundedRect: frame, xRadius: 6, yRadius: 6)
        ctx.saveGState()
        clip.addClip()
        ctx.interpolationQuality = .high
        ctx.draw(canvasImage, in: frame)
        drawAnnotations(in: ctx)
        ctx.restoreGState()

        NSColor.white.withAlphaComponent(0.25).setStroke()
        clip.lineWidth = 1
        clip.stroke()

        // 穿透中：虚线边框代替工具条（工具条窗口那时是收起来的）——
        // 反正也点不到，画出来只会误导。
        if isPassthrough {
            let dashed = NSBezierPath(
                roundedRect: frame.insetBy(dx: 1.5, dy: 1.5),
                xRadius: 6,
                yRadius: 6
            )
            dashed.setLineDash([6, 4], count: 2, phase: 0)
            dashed.lineWidth = 2
            NSColor.systemOrange.setStroke()
            dashed.stroke()
        }
    }

    private func drawAnnotations(in ctx: CGContext) {
        let layers = initialLayers + annotation.displayLayers.projected(onto: .zero, scale: 1)
        guard !layers.isEmpty else { return }

        let scale = displayScale
        ctx.saveGState()
        // 翻成「图片像素、左上原点、Y 向下」—— 和图层坐标系一致。
        ctx.translateBy(x: bounds.minX, y: bounds.maxY)
        ctx.scaleBy(x: scale, y: -scale)
        AnnotationRenderer.draw(
            layers,
            pixelatePreviews: annotation.pixelatePreviews,
            in: ctx
        )
        AnnotationRenderer.drawSelectionHint(
            selectedID: annotation.selectedID,
            layers: layers,
            strokeScale: 1 / max(scale, 0.0001),
            in: ctx
        )
        ctx.restoreGState()
    }
}
