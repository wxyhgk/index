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

    /// 鼠标（指针）模式下叠在选区上的系统选字层（Live Text）及其命中测试包装。
    /// 不再是独立开关 —— 挂载与否由 `syncLiveTextOverlay()` 从鼠标模式推导：
    /// tool == nil && pointerEngaged 时挂载，其余时候拆掉。
    private var liveTextContainer: LiveTextHitTestView?
    private var liveTextOverlay: ImageAnalysisOverlayView?

    var isLiveTextActive: Bool { liveTextOverlay != nil }
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
        // 截图工具条没有独立「选字」控件（选字并进了鼠标模式），
        // 不需要传 isLiveTextActive / toggleLiveText。
        ToolbarContext(
            annotation: annotation,
            scope: .capture,
            perform: { [weak self] actionID in self?.emit(actionID) }
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
        // 截图从中性态开始：确认选区后没有任何工具高亮，拖拽只调整选区；
        // 点「鼠标」按钮（或按 V）才进入指针模式（图层可选 + 选字）。
        annotation.pointerEngaged = false
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
            } else if let overlay = liveTextOverlay,
                      overlay.hasInteractiveItem(at: overlay.convert(local, from: self)) {
                // 鼠标模式：文字上的光标（I-beam）由系统选字层自己管，这里不抢。
            } else if annotation.tool != nil {
                NSCursor.crosshair.set()
            } else if annotation.pointerEngaged,
                      model.confirmedRect?.contains(geometry.global(fromViewLocal: local)) == true,
                      let handle = annotation.resizeHandle(
                          at: geometry.annotationPoint(fromViewLocal: local)
                      ) {
                // 鼠标模式下，选中图层的缩放控制点优先于选区自身的控制点 ——
                // 命中顺序和 mouseDown 一致；中性态不做图层命中。
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
            // 控件可能切换了工具 / 进出了鼠标模式，选字层跟着对齐。
            syncLiveTextOverlay()
            redraw()
            return
        }

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

        // 鼠标模式（tool == nil 且 pointerEngaged）下优先命中选中图层的缩放控制点；
        // 再是图层本体（选中并准备拖动）；点空处 → 取消选中 + 清掉选字层的文字选择，
        // 落回下面的选区调整逻辑。中性态（未点「鼠标」）不做图层命中 —— 拖拽只调选区。
        // 只在选区内测试：图层出了选区的部分是看不见的。
        // 文字上的点击到不了这里 —— 鼠标模式下由选字层的命中测试包装接走（拖 = 选字）。
        if model.phase == .confirmed, annotation.tool == nil, annotation.pointerEngaged,
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
            if let overlay = liveTextOverlay, overlay.hasActiveTextSelection {
                overlay.resetSelection()
            }
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
            // 鼠标模式下调整了选区：选字层贴回新位置、套用重跑的分析。
            syncLiveTextOverlayFrame()
            hoveredControlID = nil
            NSCursor.arrow.set()
        default:
            if model.endDrag() {
                if finishOnConfirm {
                    // 简单模式：确认即返回，不进 confirmed 阶段的工具条/标注流程。
                    emit(ActionID.finish)
                    return
                }
                // 每次确认选区都回到中性态：没有任何工具高亮，拖拽只调选区。
                annotation.pointerEngaged = false
                syncLiveTextOverlay()
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

    /// 右键逐级退出：选中的文字 → 图层选中 → 文字输入 → 鼠标模式退回中性 →
    /// 画笔退回中性 → 选区 → 整个截图流程（和 Esc 链一致）。
    /// 鼠标模式下文字上的右键归系统选字层（服务菜单），能落到这里的都在文字之外。
    override func rightMouseDown(with event: NSEvent) {
        if clearLiveTextSelection() {
            // 已处理：只清文字选择，不再往下退。
        } else if annotation.select(nil) {
            redraw()
        } else if annotation.isEditingText {
            annotation.endTextEditing()
            redraw()
        } else if annotation.pointerEngaged {
            annotation.pointerEngaged = false
            syncLiveTextOverlay()
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

    /// 选区确认 / 调整后立即后台预跑分析 —— 等用户进入鼠标模式时结果多半已经就绪。
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

    /// 鼠标模式（tool == nil && pointerEngaged）下应当挂着系统选字层。
    private var wantsLiveTextOverlay: Bool {
        LiveTextAnalyzer.isSupported && mode == .capture && !finishOnConfirm
            && model.phase == .confirmed
            && annotation.tool == nil && annotation.pointerEngaged
    }

    /// 让选字层的挂载状态与鼠标模式对齐。
    /// 任何切换工具 / 进出鼠标模式的路径（控件点击、快捷键、Esc、右键）都要经过它。
    /// 键盘扩展也要调，所以不是 private。
    func syncLiveTextOverlay() {
        wantsLiveTextOverlay ? mountLiveTextOverlay() : unmountLiveTextOverlay()
    }

    private func mountLiveTextOverlay() {
        guard liveTextOverlay == nil, let rect = model.confirmedRect else { return }
        // 马赛克可能是确认选区之后才画的，挂载前把分析对齐到当前状态。
        prepareLiveTextAnalysis()

        // 系统层直接盖在选区上：分析的就是选区裁剪图，内容与 view bounds 一比一，
        // 归一化坐标默认按 bounds 映射即对齐，无需 trackingImageView。
        let overlay = ImageAnalysisOverlayView()
        overlay.preferredInteractionTypes = [.textSelection]

        // 命中测试包装（见 `LiveTextHitTestView`）：图层命中交还本视图（点图层 =
        // 选图层），可交互文字给系统层（拖 = 选字），其余穿透（拖空白 = 调选区）——
        // 三种手势在鼠标模式下共存。
        let container = LiveTextHitTestView(frame: geometry.viewLocal(fromGlobal: rect))
        overlay.frame = container.bounds
        overlay.autoresizingMask = [.width, .height]
        container.addSubview(overlay)
        container.passesToHost = { [weak self, weak container] point in
            guard let self, let container else { return false }
            let local = self.convert(point, from: container)
            // 画布太小时工具条会压进选区内侧 —— 工具条命中永远优先于选字。
            if self.slots.contains(where: { $0.control != nil && $0.frame.contains(local) }) {
                return true
            }
            let canvas = self.geometry.annotationPoint(fromViewLocal: local)
            return self.annotation.resizeHandle(at: canvas) != nil
                || self.annotation.layer(at: canvas) != nil
        }
        addSubview(container)
        liveTextContainer = container
        liveTextOverlay = overlay
        applyLiveTextAnalysis()
        redraw()
    }

    private func unmountLiveTextOverlay() {
        guard liveTextOverlay != nil else { return }
        liveTextContainer?.removeFromSuperview()
        liveTextContainer = nil
        liveTextOverlay = nil
        window?.makeFirstResponder(self)
        redraw()
    }

    /// 选区被微调 / 拖动后，把选字层贴回新位置并套用按新选区重跑的分析。
    /// 调用方先跑 `prepareLiveTextAnalysis()`。键盘扩展（方向键微调）也要调。
    func syncLiveTextOverlayFrame() {
        guard let container = liveTextContainer, let rect = model.confirmedRect else { return }
        container.frame = geometry.viewLocal(fromGlobal: rect)
        applyLiveTextAnalysis()
    }

    /// 等分析任务出结果后塞进当前的系统层。任务可能是复用的（早就跑完，立即返回）；
    /// 拆层 / 换层后迟到的结果直接丢弃。
    private func applyLiveTextAnalysis() {
        let task = liveTextAnalysis?.task
        Task { [weak self, weak overlay = liveTextOverlay] in
            let analysis = await task?.value
            guard let self, let overlay, overlay === self.liveTextOverlay else { return }
            overlay.analysis = analysis
        }
    }

    /// 鼠标模式下的 ⌘C：有选中文字就复制文字（而不是整张图）。返回是否已处理。
    func copyLiveTextSelection() -> Bool {
        guard let overlay = liveTextOverlay, overlay.hasActiveTextSelection else { return false }
        Clipboard.copy(text: overlay.selectedText)
        return true
    }

    /// 选字层里有选中的文字时清掉它 —— Esc / 右键退出链的第一级。返回是否已处理。
    func clearLiveTextSelection() -> Bool {
        guard let overlay = liveTextOverlay, overlay.hasActiveTextSelection else { return false }
        overlay.resetSelection()
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

/// 鼠标模式下包住系统选字层的命中测试包装。
///
/// `ImageAnalysisOverlayView` 是 final，没法覆写它的 hitTest，所以在外面包一层，
/// 明确规定选区内事件的归属（自上而下）：
///   1. 命中标注图层 / 缩放控制点 → 返回 nil，事件穿给 `OverlayView`（点图层 = 选图层）
///   2. 命中系统层的可交互文字（`hasInteractiveItem`）→ 交给系统层（拖 = 选字）
///   3. 其余 → 返回 nil，穿给 `OverlayView`（拖空白 = 调整选区）
/// 不依赖系统层自身的穿透行为 —— 无论它吞不吞非文字区域的事件，三种手势都成立。
private final class LiveTextHitTestView: NSView {

    /// 返回 true 表示这个点该交还宿主处理（参数是本视图局部坐标）。
    var passesToHost: ((CGPoint) -> Bool)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        // 约定入参在父视图坐标系（NSView.hitTest 的语义）。
        guard let superview else { return nil }
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        if passesToHost?(local) == true { return nil }
        guard let overlay = subviews.first as? ImageAnalysisOverlayView,
              overlay.hasInteractiveItem(at: overlay.convert(local, from: self))
        else { return nil }
        // overlay 的 hitTest 期望父视图（= 本视图）坐标。
        return overlay.hitTest(local) ?? overlay
    }
}
