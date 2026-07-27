import AppKit
import VisionKit

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

    /// 简单模式：选区一确认（松手 / 单击窗口）立刻 emit，不停留在 confirmed 阶段，
    /// 工具条与标注都不会出现。滚动截图用它复用冻结选区来框选滚动区域。
    var finishOnConfirm = false

    let model: SelectionModel
    let annotation = AnnotationState()
    /// plain 模式（录屏选区）：无工具条、无标注，回车 / 双击选区返回。
    let mode: SelectionMode

    private let isPrimaryScreen: Bool
    private let imageLayer = CALayer()
    private let chrome = ChromeView()

    private var hoveredControlID: String?

    /// 选字（Live Text）模式：系统 `ImageAnalysisOverlayView` 叠在选区上，
    /// 拖选 / 复制全部原生。激活期间画标注与调整选区的手势暂停。
    private(set) var isLiveTextActive = false
    private var liveTextOverlay: ImageAnalysisOverlayView?
    /// 选区确认后预跑的分析。键含选区矩形和马赛克图层 —— 任一变了都要重跑，
    /// 马赛克参与是因为分析输入取打码后的画面（打了码的字不该还能选出来）。
    private var liveTextAnalysis: (rect: CGRect, pixelates: Layers<ImageSpace>, task: Task<ImageAnalysis?, Never>)?

    /// 光标位置（视图局部）与该处的像素采样。选区阶段才有意义。
    private var cursor: CGPoint?
    private(set) var cursorSample: PixelSample?

    /// ⌥ 是否按着。悬停窗口时按住 ⌥ = 整窗捕获模式（紫框 +「完整窗口」标签）。
    private var optionHeld = false

    /// 整窗捕获只在正式截图模式下开放 —— 录屏选区和滚动截图只要一个矩形。
    private var allowsFullWindowCapture: Bool {
        mode == .capture && !finishOnConfirm
    }

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
            perform: { [weak self] actionID in self?.emit(actionID) },
            isLiveTextActive: { [weak self] in self?.isLiveTextActive ?? false },
            // 不支持的机型不传 toggle → 「选字」控件整个不出现。
            toggleLiveText: LiveTextAnalyzer.isSupported
                ? { [weak self] in self?.toggleLiveText() }
                : nil
        )
    }

    /// 工具条布局按需计算：绘制和命中测试用的是同一份结果，不可能不一致。
    /// plain 模式恒为空 —— 工具条既不绘制也不参与命中。
    private var slots: [ToolbarSlot] {
        guard mode == .capture, model.phase == .confirmed,
              let rect = model.confirmedRect else { return [] }
        return ToolbarLayout.slots(in: bounds, config: .init(
            anchor: geometry.viewLocal(fromGlobal: rect),
            alignment: .trailing,
            context: toolbarContext
        ))
    }

    init(model: SelectionModel, isPrimaryScreen: Bool, mode: SelectionMode = .capture) {
        self.model = model
        self.isPrimaryScreen = isPrimaryScreen
        self.mode = mode
        super.init(frame: .zero)

        // 覆盖层画布是显示器的点；测量标注要报图像像素，倍率从冻结快照取。
        annotation.pixelScale = Double(model.snapshot.scale)
        // 水印字号按「成品图宽 3%」烤入；成品宽 = 选区宽（点）× 缩放倍率。
        // 闭包按需取值 —— 开关水印的那一刻选区是多大就按多大算。
        annotation.imagePixelWidthProvider = { [model] in
            Double((model.confirmedRect?.width ?? 0) * model.snapshot.scale)
        }

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
                toolbarContext: self.toolbarContext,
                hoveredControlID: self.hoveredControlID,
                isPrimaryScreen: self.isPrimaryScreen,
                confirmHint: self.mode == .plain ? "⏎ 开始录制 · 双击选区 · ⎋ 取消" : nil,
                fullWindowHint: self.optionHeld && self.allowsFullWindowCapture,
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
            } else if isLiveTextActive {
                // 选字模式：选区上的光标（I-beam）由系统 overlay 自己管，
                // 这里不抢；选区外恢复箭头。
                if model.confirmedRect?.contains(geometry.global(fromViewLocal: local)) != true {
                    NSCursor.arrow.set()
                }
            } else if annotation.tool != nil {
                NSCursor.crosshair.set()
            } else if model.confirmedRect?.contains(geometry.global(fromViewLocal: local)) == true,
                      let handle = annotation.resizeHandle(
                          at: geometry.annotationPoint(fromViewLocal: local)
                      ) {
                // 选中图层的缩放控制点优先于选区自身的控制点 —— 命中顺序和 mouseDown 一致。
                handle.cursor.set()
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

    /// ⌥ 按下 / 松开要立刻反映到窗口高亮上（紫框 ↔ 蓝框），所以监听 flagsChanged。
    override func flagsChanged(with event: NSEvent) {
        let held = event.modifierFlags.contains(.option)
        if held != optionHeld {
            optionHeld = held
            // 只有 idle 悬停窗口阶段有视觉差异；其余阶段重绘无害但没必要。
            if model.phase == .idle { redraw() }
        }
        super.flagsChanged(with: event)
    }

    /// 光标映射在 `ResizeHandle.cursor`（AppKit 没有公开的斜向缩放光标，四角退回十字）。
    private func cursor(for handle: SelectionModel.Handle?) -> NSCursor {
        handle?.cursor ?? .crosshair
    }

    /// 捕获信息层的「App 名+版本」：按窗口归因的 pid 查在跑的 App，版本从其
    /// bundle 读（和 `MetadataCollector.collect` 同一取法）；查不到退回
    /// CGWindowList 的 ownerName。只在激活工具条控件时取一次，都是内存操作。
    private func captureInfoApp(for window: WindowInfo?) -> String? {
        guard let window else { return nil }
        let runningApp = NSRunningApplication(processIdentifier: window.pid)
        let version = runningApp?.bundleURL
            .flatMap { Bundle(url: $0)?.infoDictionary?["CFBundleShortVersionString"] as? String }
        return CaptureInfoSpec.appDescription(
            name: runningApp?.localizedName ?? window.ownerName,
            version: version
        )
    }

    override func mouseDown(with event: NSEvent) {
        let local = localPoint(of: event)

        // 工具条命中优先
        if model.phase == .confirmed,
           let control = slots.first(where: { $0.control != nil && $0.frame.contains(local) })?.control {
            // 套壳（frame）/ 捕获信息要用的真实元数据：窗口归因在确认选区时已定，
            // 激活前取一次最新值；浏览器 URL 是落库后异步回填的，截图这一刻还没有
            // → 留空，浏览器壳的地址栏画成空胶囊、信息栏不排网址那一段。
            annotation.frameDefaultTitle = model.confirmedWindow?.title
            annotation.captureInfoDefaultApp = captureInfoApp(for: model.confirmedWindow)
            control.activate(toolbarContext)
            // 选字模式下点了别的工具（画笔 / 指针）→ 自动退出选字。
            if isLiveTextActive, control.group == .tools, control.id != LiveTextControl.controlID {
                exitLiveText()
            }
            redraw()
            return
        }

        // 选字模式：选区上的事件归系统 overlay（它是子视图，命中优先）；
        // 落到这里的点击一律忽略 —— 不调整选区、不画标注，
        // 退出只走控件 / Esc / 切工具。
        if isLiveTextActive { return }

        let global = geometry.global(fromViewLocal: local)
        hoveredControlID = nil

        // ⌥+单击窗口 = 整窗捕获（不含遮挡），不进标注阶段，直接完成。
        if allowsFullWindowCapture, model.phase == .idle,
           event.modifierFlags.contains(.option) {
            // 这块屏可能因为别的屏正在操作而被标记 inactive（hover 会被吞掉）——
            // 用户既然点到这里了，就把它激活。
            model.setInactive(false)
            model.hover(at: global)
            if let window = model.hoveredWindow {
                emitFullWindow(window)
                return
            }
        }

        // plain 模式（录屏选区）：双击选区内部 = 确认返回。
        if mode == .plain, model.phase == .confirmed, event.clickCount == 2,
           model.confirmedRect?.contains(global) == true {
            emit(ActionID.finish)
            return
        }

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

        // 指针模式下优先命中选中图层的缩放控制点；再是图层本体（选中并准备拖动）；
        // 点空处 → 取消选中，落回下面的选区调整逻辑。
        // 只在选区内测试：图层出了选区的部分是看不见的。
        if model.phase == .confirmed, annotation.tool == nil,
           let selection = model.confirmedRect, selection.contains(global) {
            let canvas = geometry.annotationPoint(fromViewLocal: local)
            if let handle = annotation.resizeHandle(at: canvas) {
                annotation.endTextEditing()
                annotation.beginResize(handle: handle, at: canvas)
                onBecameActive?(self)
                redraw()
                return
            }
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
        if annotation.isResizing {
            redrawIfNeeded(annotation.updateResize(to: geometry.annotationPoint(fromViewLocal: local)))
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
        if annotation.isResizing {
            annotation.endResize(pixelSource: frozenPixels)
            redraw()
            return
        }

        switch model.phase {
        case .adjusting:
            model.endAdjust()
            prepareLiveTextAnalysis()
            hoveredControlID = nil
            NSCursor.arrow.set()
        default:
            if model.endDrag() {
                if finishOnConfirm {
                    // 简单模式：确认即返回，不进 confirmed 阶段的工具条/标注流程。
                    emit(ActionID.finish)
                    return
                }
                prepareLiveTextAnalysis()
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

    /// 右键逐级退出：选字模式 → 图层选中 → 文字输入 → 标注工具 → 选区 → 整个截图流程。
    /// 选字模式下选区内的右键归系统 overlay（服务菜单），能落到这里的都在选区外。
    override func rightMouseDown(with event: NSEvent) {
        if isLiveTextActive {
            exitLiveText()
        } else if annotation.select(nil) {
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

    // MARK: - 选字（Live Text）

    /// 选区确认 / 调整后立即后台预跑分析 —— 等用户点「选字」时结果多半已经就绪。
    /// 幂等：键（选区矩形 + 马赛克图层）没变就直接复用在跑 / 跑完的任务。
    /// 键盘扩展（方向键微调）也要调，所以不是 private。
    func prepareLiveTextAnalysis() {
        guard LiveTextAnalyzer.isSupported, mode == .capture, !finishOnConfirm,
              model.phase == .confirmed, let rect = model.confirmedRect else { return }
        let pixelates = annotation.exportLayers(
            selection: geometry.annotationRect(fromGlobal: rect),
            scale: model.snapshot.scale
        ).filter { $0.kind == .pixelate }
        if let cached = liveTextAnalysis, cached.rect == rect, cached.pixelates == pixelates {
            return
        }
        guard let crop = model.makeCroppedImage() else { return }
        liveTextAnalysis?.task.cancel()
        // 分析输入取打码后的画面 —— 马赛克底下的字不该还能被拖选出来。
        let image = pixelates.isEmpty ? crop : LayerRenderer.render(base: crop, layers: pixelates)
        liveTextAnalysis = (rect, pixelates, Task { await LiveTextAnalyzer.analyze(image) })
    }

    private func toggleLiveText() {
        isLiveTextActive ? exitLiveText() : enterLiveText()
    }

    private func enterLiveText() {
        guard !isLiveTextActive, model.phase == .confirmed,
              let rect = model.confirmedRect else { return }
        annotation.endTextEditing()
        annotation.select(nil)
        annotation.tool = nil
        isLiveTextActive = true

        // 马赛克可能是确认选区之后才画的，进模式前把分析对齐到当前状态。
        prepareLiveTextAnalysis()

        // 系统层直接盖在选区上：分析的就是选区裁剪图，内容与 view bounds 一比一，
        // 归一化坐标默认按 bounds 映射即对齐，无需 trackingImageView。
        let overlay = ImageAnalysisOverlayView()
        overlay.preferredInteractionTypes = [.textSelection]
        overlay.frame = geometry.viewLocal(fromGlobal: rect)
        addSubview(overlay)
        liveTextOverlay = overlay

        let task = liveTextAnalysis?.task
        Task { [weak self, weak overlay] in
            let analysis = await task?.value
            guard let self, let overlay,
                  self.isLiveTextActive, overlay === self.liveTextOverlay else { return }
            overlay.analysis = analysis
        }
        redraw()
    }

    /// 退出选字：拆掉系统层，键盘焦点收回来。键盘扩展也要用，所以不是 private。
    func exitLiveText() {
        guard isLiveTextActive else { return }
        isLiveTextActive = false
        liveTextOverlay?.removeFromSuperview()
        liveTextOverlay = nil
        window?.makeFirstResponder(self)
        redraw()
    }

    /// 选字模式下的 ⌘C：有选中文字就复制文字（而不是整张图）。返回是否已处理。
    func copyLiveTextSelection() -> Bool {
        guard let overlay = liveTextOverlay, overlay.hasActiveTextSelection else { return false }
        Clipboard.copy(text: overlay.selectedText)
        return true
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
            layers: layers,
            windowCaptureRequest: nil
        ))
    }

    /// ⌥+单击的整窗捕获出口。`image` 放冻结画面上窗口可见部分的裁剪 ——
    /// 协调器异步用 SCK 重拍完整窗口，只有窗口已经消失时才落回这份兜底。
    private func emitFullWindow(_ window: WindowInfo) {
        let visible = window.frame.intersection(model.bounds)
        guard let fallback = model.snapshot.crop(globalRect: visible) else { return }

        onFinish?(SelectionResult(
            region: window.frame,
            display: model.snapshot.display,
            window: window,
            actionID: ActionID.finish,
            image: fallback,
            layers: Layers<ImageSpace>(),
            windowCaptureRequest: window
        ))
    }
}
