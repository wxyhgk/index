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

    // MARK: - 组合持有的子状态（原散在主视图的可变状态已下沉）

    /// 交互状态：工具条悬停与 ⌥ 按压（窗口高亮）。读写分散在鼠标与键盘两类事件，
    /// 集中一处便于追踪「谁改了悬停」。
    let interactionState = OverlayInteractionState()
    /// 放大镜状态：光标位置与像素采样。仅在挑选阶段有效。
    let magnifierState = OverlayMagnifierState()
    /// 选字层宿主：容器视图、系统覆盖层与预跑分析任务。
    let liveTextHost = LiveTextOverlayHost()

    // 兼容访问：外部仍可读事件路由关心的派生状态，存储已下沉至对应小组件。
    var isLiveTextActive: Bool { liveTextHost.isActive }
    /// 兼容桥：历史调用点通过 `liveTextOverlay` 直接取值，现转发至宿主。
    var liveTextOverlay: ImageAnalysisOverlayView? { liveTextHost.overlay }
    var liveTextContainer: LiveTextHitTestView? { liveTextHost.container }
    var liveTextAnalysis: (rect: CGRect, pixelates: Layers<ImageSpace>, task: Task<ImageAnalysis?, Never>)?
    { get { liveTextHost.analysis } set { liveTextHost.analysis = newValue } }
    var cursor: CGPoint? { get { magnifierState.cursor } set { magnifierState.cursor = newValue } }
    var cursorSample: PixelSample? { get { magnifierState.cursorSample } set { magnifierState.cursorSample = newValue } }
    var hoveredControlID: String? { get { interactionState.hoveredControlID } set { interactionState.hoveredControlID = newValue } }
    var optionHeld: Bool { get { interactionState.optionHeld } set { interactionState.optionHeld = newValue } }

    /// 整窗捕获只在正式截图模式下开放 —— 录屏选区和滚动截图只要一个矩形。
    private var allowsFullWindowCapture: Bool {
        mode == .capture && !finishOnConfirm
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
    ///
    /// 尺寸只由可见控件决定：选区从很小拖到全屏，工具条一个像素都不变，
    /// 变的只有它贴在选区下方（放不下时上方 / 内侧）的位置。
    var slots: [ToolbarSlot] {
        guard mode == .capture, model.phase == .confirmed,
              let rect = model.confirmedRect else { return [] }
        return ToolbarLayout.slots(
            in: bounds,
            anchor: geometry.viewLocal(fromGlobal: rect),
            context: toolbarContext
        )
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
        // 效果层的注入上下文（覆盖层这一处，与钉图/编辑器同一契约）。
        // 闭包按开关那一刻取值：成品宽 = 选区宽（点）× 缩放倍率；
        // 元数据从确认选区时的窗口归因取（浏览器 URL 是落库后异步回填的，
        // 此刻还没有 → 留空）；捕获时刻不注入 —— 截图那一刻就是当下。
        annotation.effectContext = { [model] in
            let style = AppSettings.shared
            var context = EffectContext()
            context.imagePixelWidth =
                Double((model.confirmedRect?.width ?? 0) * model.snapshot.scale)
            context.imagePixelHeight =
                Double((model.confirmedRect?.height ?? 0) * model.snapshot.scale)
            context.windowTitle = model.confirmedWindow?.title
            context.appDescription = Self.captureInfoApp(for: model.confirmedWindow)
            context.watermarkText = style.watermarkText
            context.watermarkMode = style.watermarkMode
            context.watermarkAlpha = style.watermarkAlpha
            context.backdropPaddingRatio = style.backdropPaddingRatio
            context.backdropCornerRatio = style.backdropCornerRatio
            context.backdropShadowRatio = style.backdropShadowRatio
            context.backdropShadowAlpha = style.backdropShadowAlpha
            return context
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
    /// CGWindowList 的 ownerName。只在开启效果时取一次，都是内存操作。
    private static func captureInfoApp(for window: WindowInfo?) -> String? {
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
            // 效果层要用的真实元数据不在这里注入 —— init 里设的
            // `annotation.effectContext` 闭包会在开关那一刻现取窗口归因。
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
            let oldRect = model.confirmedRect
            let wasMove = model.adjustingHandle?.isMove == true
            model.updateAdjust(to: global)
            if wasMove, let oldRect, let newRect = model.confirmedRect {
                let dx = newRect.origin.x - oldRect.origin.x
                let dy = newRect.origin.y - oldRect.origin.y
                // AppKit Y 向上，画布 Y 向下
                let deltaCanvas = CGPoint(x: dx, y: -dy)
                annotation.translateAll(by: deltaCanvas)
            }
        default:
            model.updateDrag(to: global)
        }
        redraw()
    }

    override func scrollWheel(with event: NSEvent) {
        // PixPin：工具条右侧调节区 + 滚轮改粗细。只要当前工具有 width 轴，
        // 且滚轮发生在工具条范围内（或hover在样式控件上），就步进粗细。
        // 不与选区缩放手势冲突：滚动量很小时不吞事件，让父视图/系统处理。
        guard model.phase == .confirmed,
              annotation.styleAxes.contains(.width)
        else {
            super.scrollWheel(with: event)
            return
        }
        let local = localPoint(of: event)
        let styleSlots = slots.filter { $0.control?.group == .style }
        let isOverStyle = styleSlots.contains { $0.frame.contains(local) }
        // 兼容触摸板：任意在样式行上的滚轮即视为意图；不在样式行则仅当有hover时忽略，
        // 避免在画布中间滚轮误改粗细。
        let shouldHandle: Bool = {
            if isOverStyle { return true }
            // 悬停在任意样式控件上（如刚从工具条移开但仍有hoveredControlID）
            if let hovered = hoveredControlID,
               styleSlots.contains(where: { $0.control?.id == hovered }) { return true }
            // PixPin 也支持在画布上直接滚轮改粗细：当已选框选工具时，滚轮即改粗细
            if annotation.tool == .rect || annotation.tool == .ellipse { return true }
            return false
        }()
        guard shouldHandle else {
            super.scrollWheel(with: event)
            return
        }
        let delta = event.scrollingDeltaY
        guard delta != 0 else { super.scrollWheel(with: event); return }
        // 小数防抖：触控板连续小增量，累积到阈值再步进
        let step = delta > 0 ? 1 : -1
        if annotation.stepWidth(by: step) {
            redraw()
        }
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

    // Live Text 已抽至 OverlayView+LiveText.swift
    // 保留 wantsLiveTextOverlay 的访问级别供扩展读取

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

// LiveTextHitTestView 已移至 OverlayView+LiveText.swift，与 LiveTextOverlayHost 同处。
