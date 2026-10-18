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
    let annotation: AnnotationState
    /// plain 模式（录屏选区）：无工具条、无标注，回车 / 双击选区返回。
    let mode: SelectionMode
    /// 截图行为偏好（放大镜 / 回车语义）。注入式：装配点传窄协议切片。
    /// 键盘/放大镜扩展在别的文件读它，不能 private。
    let capture: any CapturePreferences
    /// 标注样式持久化通道（水印 / 底壳 / 工具样式）。
    private let annotationStyle: any AnnotationStylePreferences

    private let isPrimaryScreen: Bool
    private let imageLayer = CALayer()
    private let chrome = ChromeView()
    private var isMouseOverToolbar: Bool = false
    private var toolbarToolTipTags: [NSView.ToolTipTag] = []
    private var toolbarToolTipOwners: [NSView.ToolTipTag: ToolbarToolTipOwner] = [:]
    private var toolbarToolTipSignature = ""
    /// 控制点淡入进度（选区确认时 0→1，0.15s 3 步）。
    private var handleAlpha: CGFloat = 1
    /// 当前 hover 的 resize handle（用于 hover 放大反馈）。nil = 无。
    private var hoveredHandle: SelectionModel.Handle?
    /// 当前 hover 的圆角控制点（hover 放大反馈）。nil = 无。
    private var hoveredCorner: SelectionModel.Corner?

    // MARK: - 组合持有的子状态（原散在主视图的可变状态已下沉）

    /// 交互状态：工具条悬停与 ⌥ 按压（窗口高亮）。读写分散在鼠标与键盘两类事件，
    /// 集中一处便于追踪「谁改了悬停」。
    let interactionState = OverlayInteractionState()
    /// 放大镜状态：光标位置与像素采样。仅在挑选阶段有效。
    let magnifierState = OverlayMagnifierState()
    /// 选字层宿主：容器视图、系统覆盖层与预跑分析任务。
    let liveTextHost = LiveTextOverlayHost()
    /// AI 选区宿主：共享状态机 + Capture 坐标薄适配。
    let selectionAIHost = OverlaySelectionAIHost()
    /// AI 请求状态独立持有，不塞进几何会话。
    let selectionAIExecution: OverlaySelectionAIExecution

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
    var pressedControlID: String? { get { interactionState.pressedControlID } set { interactionState.pressedControlID = newValue } }
    var focusedControlID: String? { get { interactionState.focusedControlID } set { interactionState.focusedControlID = newValue } }
    var optionHeld: Bool { get { interactionState.optionHeld } set { interactionState.optionHeld = newValue } }

    /// 整窗捕获只在正式截图模式下开放 —— 录屏选区和滚动截图只要一个矩形。
    /// gesture target 经 `OverlayGestureHost` 读它，不能 private。
    var allowsFullWindowCapture: Bool {
        mode == .capture && !finishOnConfirm
    }

    /// 事件路由器：鼠标五事件的全部优先级逻辑在这里（见 `OverlayInteractionRouter`）。
    let router = OverlayInteractionRouter(targets: OverlayInteractionRouter.defaultTargets())

    var geometry: OverlayGeometry {
        OverlayGeometry(bounds: bounds, displayOrigin: model.bounds.origin)
    }

    var toolbarContext: ToolbarContext {
        ToolbarContext(
            annotation: annotation,
            scope: .capture,
            perform: { [weak self] actionID in self?.emit(actionID) },
            capabilities: mode == .capture && !finishOnConfirm
                ? ToolbarHostCapabilities(modes: [
                    .selectionAI: ToolbarHostModeCapability(
                        isActive: { [weak self] in self?.selectionAIHost.isActive ?? false },
                        activate: { [weak self] in self?.activateSelectionAI() },
                        deactivate: { [weak self] in self?.deactivateSelectionAI() }
                    )
                ])
                : .none
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

    /// 一帧的全部绘制输入。`chrome.render` 与任何想「看当前画面状态」的
    /// 调用方都从这里取，不再各自拼 19 个参数。
    var renderState: OverlayRenderState {
        OverlayRenderState(
            model: model,
            annotation: annotation,
            slots: slots,
            toolbarContext: toolbarContext,
            toolbarOpacity: isMouseOverToolbar ? 1.0 : 0.55,
            hoveredControlID: hoveredControlID,
            pressedControlID: pressedControlID,
            focusedControlID: focusedControlID,
            selectionAIIsActive: selectionAIHost.isActive,
            selectionAIRect: selectionAIViewRect,
            selectionAITaskSlots: selectionAITaskSlots,
            hoveredSelectionAITask: interactionState.hoveredSelectionAITask,
            pressedSelectionAITask: interactionState.pressedSelectionAITask,
            selectionAIStatus: selectionAIExecution.status,
            selectionAIResult: selectionAIResultRenderState,
            isPrimaryScreen: isPrimaryScreen,
            confirmHint: mode == .plain ? "⏎ 开始录制 · 双击选区 · ⎋ 取消" : nil,
            fullWindowHint: optionHeld && allowsFullWindowCapture,
            magnifier: magnifierPayload,
            handleAlpha: handleAlpha,
            hoveredHandle: hoveredHandle,
            hoveredCorner: hoveredCorner
        )
    }

    init(
        model: SelectionModel,
        isPrimaryScreen: Bool,
        mode: SelectionMode = .capture,
        capture: any CapturePreferences,
        annotationStyle: any AnnotationStylePreferences,
        selectionAIExecution: OverlaySelectionAIExecution? = nil
    ) {
        self.model = model
        self.isPrimaryScreen = isPrimaryScreen
        self.mode = mode
        self.capture = capture
        self.annotationStyle = annotationStyle
        self.annotation = AnnotationState(styleStore: annotationStyle)
        self.selectionAIExecution = selectionAIExecution ?? OverlaySelectionAIExecution()
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
        annotation.effectContext = { [model, annotationStyle] in
            var context = EffectContext()
            context.imagePixelWidth =
                Double((model.confirmedRect?.width ?? 0) * model.snapshot.scale)
            context.imagePixelHeight =
                Double((model.confirmedRect?.height ?? 0) * model.snapshot.scale)
            context.windowTitle = model.confirmedWindow?.title
            context.appDescription = Self.captureInfoApp(for: model.confirmedWindow)
            context.watermarkText = annotationStyle.watermarkText
            context.watermarkMode = annotationStyle.watermarkMode
            context.watermarkAlpha = annotationStyle.watermarkAlpha
            context.backdropPaddingRatio = annotationStyle.backdropPaddingRatio
            context.backdropCornerRatio = annotationStyle.backdropCornerRatio
            context.backdropShadowRatio = annotationStyle.backdropShadowRatio
            context.backdropShadowAlpha = annotationStyle.backdropShadowAlpha
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
            OverlayRenderer.draw(state: renderState, in: bounds, ctx: ctx)
        }
        addSubview(chrome)
        self.selectionAIExecution.onChange = { [weak self] in self?.redraw() }
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
        syncToolbarToolTips()
        chrome.needsDisplay = true
    }

    private func syncToolbarToolTips() {
        let entries = slots.compactMap { slot -> (CGRect, String)? in
            guard let control = slot.control else { return nil }
            return (slot.frame, control.accessibilityLabel(toolbarContext))
        }
        let signature = entries.map { "\(NSStringFromRect($0.0)):\($0.1)" }.joined(separator: "|")
        guard signature != toolbarToolTipSignature else { return }
        clearToolbarToolTips()
        toolbarToolTipTags = entries.map { frame, label in
            let owner = ToolbarToolTipOwner(label)
            let tag = addToolTip(frame, owner: owner, userData: nil)
            toolbarToolTipOwners[tag] = owner
            return tag
        }
        toolbarToolTipSignature = signature
    }

    /// 覆盖层下线前主动取消 AppKit 的延迟 tooltip timer，避免 owner 已释放后回调。
    func clearToolbarToolTips() {
        toolbarToolTipTags.forEach(removeToolTip)
        toolbarToolTipTags.removeAll()
        toolbarToolTipOwners.removeAll()
        toolbarToolTipSignature = ""
    }

    private func localPoint(of event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil)
    }

    // MARK: - 鼠标

    override func mouseMoved(with event: NSEvent) {
        if model.isPolygonMode {
            model.updatePolygonPreview(geometry.global(fromViewLocal: localPoint(of: event)))
            redraw()
            return
        }
        let local = localPoint(of: event)
        // 工具条 hover：鼠标在工具条区域内时完全不透明，否则半透明（PixPin Mouse Penetration 效果）。
        let overToolbar = model.phase == .confirmed && slots.contains { $0.hitFrame.contains(local) }
        if overToolbar != isMouseOverToolbar {
            isMouseOverToolbar = overToolbar
            needsDisplay = true
        }
        // 控制点 hover（confirmed/adjusting 阶段，无工具在手时追踪 resize handle + 圆角控制点）。
        if model.showsHandles, annotation.tool == nil {
            let global = geometry.global(fromViewLocal: local)
            let hit = model.handle(at: global)
            let resizeHit = (hit?.isMove == false) ? hit : nil
            if resizeHit != hoveredHandle {
                hoveredHandle = resizeHit
                needsDisplay = true
            }
            let cornerHit = model.cornerControl(at: global)
            if cornerHit != hoveredCorner {
                hoveredCorner = cornerHit
                needsDisplay = true
            }
        } else if hoveredHandle != nil || hoveredCorner != nil {
            hoveredHandle = nil
            hoveredCorner = nil
            needsDisplay = true
        }
        router.mouseMoved(local: local, event: event, host: self)
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

    /// 捕获信息层的「App 名+版本」。平台读取收在 `MetadataCollector`。
    private static func captureInfoApp(for window: WindowInfo?) -> String? {
        MetadataCollector.appDescription(for: window)
    }

    override func mouseDown(with event: NSEvent) {
        if model.isPolygonMode {
            super.mouseDown(with: event)
            return
        }
        let vertexGlobal = geometry.global(fromViewLocal: localPoint(of: event))
        if let vertexIndex = model.polygonVertex(at: vertexGlobal) {
            model.beginPolygonVertexAdjust(vertexIndex, at: vertexGlobal)
            NSCursor.openHand.set()
            return
        }
        router.mouseDown(local: localPoint(of: event), event: event, host: self)
    }

    override func mouseDragged(with event: NSEvent) {
        if model.isPolygonMode {
            model.updatePolygonPreview(geometry.global(fromViewLocal: localPoint(of: event)))
            redraw()
            return
        }
        if model.adjustingPolygonVertex != nil {
            model.updatePolygonVertex(to: geometry.global(fromViewLocal: localPoint(of: event)))
            redraw()
            return
        }
        router.mouseDragged(local: localPoint(of: event), event: event, host: self)
    }

    override func scrollWheel(with event: NSEvent) {
        // 滚轮调整图层特殊参数（如放大镜倍率）：鼠标悬停在支持滚轮调整的图层上即生效。
        if model.phase == .confirmed {
            let local = localPoint(of: event)
            let canvasPoint = geometry.annotationPoint(fromViewLocal: local)
            let tolerance = 8 * annotation.strokeScale
            for layer in annotation.displayLayers.elements.reversed() where !layer.kind.isEffect {
                guard let descriptor = ToolRegistry.descriptor(for: layer.kind),
                      descriptor.supportsScroll,
                      descriptor.hitTest(layer, at: canvasPoint, tolerance: tolerance) else { continue }
                if annotation.scrollAdjust(layer.id, deltaY: event.scrollingDeltaY) {
                    self.redraw()
                    return
                }
            }
        }
        // PixPin：工具条右侧调节区 + 滚轮改粗细/字号。
        // 只要当前工具有 width 或 fontSize 轴，滚轮即步进（stepWidth 内部优先 width，
        // 无 width 时步进 fontSize）。
        guard model.phase == .confirmed,
              annotation.styleAxes.contains(.width) || annotation.styleAxes.contains(.fontSize)
        else {
            interactionState.widthScroll.reset()
            super.scrollWheel(with: event)
            return
        }
        let local = localPoint(of: event)
        let styleSlots = slots.filter { $0.control?.group == .style }
        let isOverStyle = styleSlots.contains { $0.hitFrame.contains(local) }
        // 兼容触摸板：任意在样式行上的滚轮即视为意图；不在样式行则仅当有hover时忽略，
        // 避免在画布中间滚轮误改粗细。
        let shouldHandle: Bool = {
            if isOverStyle { return true }
            // 悬停在任意样式控件上（如刚从工具条移开但仍有hoveredControlID）
            if let hovered = hoveredControlID,
               styleSlots.contains(where: { $0.control?.id == hovered }) { return true }
            // PixPin：拿着任何有 width 轴的工具，在画布上滚轮即改粗细
            return true
        }()
        guard shouldHandle else {
            interactionState.widthScroll.reset()
            super.scrollWheel(with: event)
            return
        }
        if !event.momentumPhase.isEmpty {
            if event.momentumPhase.contains(.ended) { interactionState.widthScroll.reset() }
            return
        }
        guard let step = interactionState.widthScroll.step(
            delta: event.scrollingDeltaY,
            isPrecise: event.hasPreciseScrollingDeltas
        ) else { return }
        if annotation.stepWidth(by: step) {
            redraw()
        }
    }

    override func mouseUp(with event: NSEvent) {
        if model.isPolygonMode {
            if model.polygon?.snapToFirst == true {
                if model.confirmPolygon() {
                    enterConfirmedState()
                }
            } else {
                model.addPolygonPoint(geometry.global(fromViewLocal: localPoint(of: event)))
            }
            redraw()
            super.mouseUp(with: event)
            return
        }
        if model.adjustingPolygonVertex != nil {
            model.endPolygonVertexAdjust()
            NSCursor.arrow.set()
            redraw()
            return
        }
        router.mouseUp(local: localPoint(of: event), event: event, host: self)
    }

    /// 选区确认后的统一收尾：退出指针模式、对齐选字层、
    /// 清悬停、光标回箭头。任何进入 confirmed 的路径都走这里，
    /// 新增副作用只加这一处。
    func enterConfirmedState() {
        enterConfirmedState(saveToHistory: true)
    }

    func enterConfirmedState(saveToHistory: Bool) {
        if saveToHistory {
            saveSelectionToHistory()
        }
        annotation.pointerEngaged = false
        syncLiveTextOverlay()
        prepareLiveTextAnalysis()
        hoveredControlID = nil
        NSCursor.arrow.set()
        animateHandlesIn()
    }

    // MARK: 选区历史（R / Shift+R 复用）

    private static let historyKey = "index.captureRectHistory"
    private static let maxHistoryCount = 10
    private var historyIndex = 0

    private func saveSelectionToHistory() {
        guard let rect = model.confirmedRect else { return }
        let entry: [String: Double] = [
            "x": rect.origin.x, "y": rect.origin.y,
            "w": rect.size.width, "h": rect.size.height,
            "display": Double(model.snapshot.display.id),
            "radius": Double(model.cornerRadius)
        ]
        var history = Self.loadHistory()
        if history.first != entry {
            history.insert(entry, at: 0)
        }
        if history.count > Self.maxHistoryCount {
            history = Array(history.prefix(Self.maxHistoryCount))
        }
        UserDefaults.standard.set(history, forKey: Self.historyKey)
        historyIndex = 0
    }

    private static func loadHistory() -> [[String: Double]] {
        (UserDefaults.standard.array(forKey: historyKey) as? [[String: Double]]) ?? []
    }

    /// R 键（重置到最近）/ Shift+R（往更早翻页）：恢复历史选区。
    func handleHistoryKey(shift: Bool) -> Bool {
        guard model.phase == .idle else { return false }
        let targetIndex = shift ? historyIndex + 1 : 0
        guard targetIndex < Self.loadHistory().count else { return false }
        guard restoreSelectionAt(targetIndex) else { return false }
        historyIndex = targetIndex
        return true
    }

    private func restoreSelectionAt(_ index: Int) -> Bool {
        guard model.phase == .idle, index >= 0 else { return false }
        let history = Self.loadHistory()
        guard index < history.count else { return false }
        let entry = history[index]
        let displayID = model.snapshot.display.id
        guard Int(entry["display"] ?? 0) == displayID,
              let x = entry["x"], let y = entry["y"],
              let w = entry["w"], let h = entry["h"],
              w > 0, h > 0
        else { return false }
        let radius = CGFloat(entry["radius"] ?? 0)
        guard model.restoreSelection(
            CGRect(x: x, y: y, width: w, height: h),
            cornerRadius: radius
        ) else { return false }
        enterConfirmedState(saveToHistory: false)
        redraw()
        return true
    }

    /// 控制点淡入：3 步 × 50ms（0→0.4→0.7→1.0），视觉上接近 0.15s 渐变。
    private func animateHandlesIn() {
        handleAlpha = 0
        redraw()
        let steps: [(delay: TimeInterval, alpha: CGFloat)] = [
            (0.05, 0.4),
            (0.10, 0.7),
            (0.15, 1.0)
        ]
        for (delay, alpha) in steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                self.handleAlpha = alpha
                self.redraw()
            }
        }
    }

    /// 马赛克要从冻结画面取原始像素：标注空间是显示器局部左上原点，先换回 AppKit 全局。
    /// gesture target 经 `OverlayGestureHost` 调它，不能 private。
    func frozenPixels(_ rect: CGRect) -> CGImage? {
        let snapshot = model.snapshot
        return snapshot.crop(globalRect: CGRect(
            x: snapshot.frame.minX + rect.minX,
            y: snapshot.frame.maxY - rect.maxY,
            width: rect.width,
            height: rect.height
        ))
    }

    func sampleColor(atGlobal point: CGPoint) -> LColor? {
        model.snapshot.sample(aroundGlobal: point)?.color
    }

    /// 右键逐级退出：选中的文字 → 图层选中 → 文字输入 → 鼠标模式退回中性 →
    /// 画笔退回中性 → 选区 → 整个截图流程。Esc 与它刻意不同：Esc 一次
    /// 取消整次截图，右键才承担“退回上一层”的精细操作。
    /// 鼠标模式下文字上的右键归系统选字层（服务菜单），能落到这里的都在文字之外。
    ///
    /// 返回 false 表示整次截图流程已取消（onFinish 已发）。
    @discardableResult
    func stepBackOneLevel() -> Bool {
        if stepBackSelectionAI() {
            redraw()
        } else if clearLiveTextSelection() {
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
            return false
        }
        return true
    }

    override func rightMouseDown(with event: NSEvent) {
        stepBackOneLevel()
    }

    // Live Text 已抽至 OverlayView+LiveText.swift
    // 保留 wantsLiveTextOverlay 的访问级别供扩展读取

    // MARK: - 收尾

    func cancel() {
        onFinish?(nil)
    }

    func emit(_ actionID: String) {
        // "x" 关闭 = 取消整次截图（不保存），和 ESC 取消一致。
        if actionID == ActionID.close {
            annotation.endTextEditing()
            onFinish?(nil)
            return
        }
        // 自动马赛克：不结束截图，异步 OCR 后批量加 pixelate 图层。
        if actionID == ActionID.autoMosaic {
            performAutoMosaic()
            return
        }
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

    /// 自动马赛克：Vision API 检测选区内文字区域，批量添加 pixelate 图层。
    func performAutoMosaic() {
        guard model.phase == .confirmed, let region = model.confirmedRect else { return }
        guard let image = model.makeCroppedImage() else { return }
        let scale = model.snapshot.scale
        let displayFrame = model.snapshot.frame
        let offsetX = region.minX - displayFrame.minX
        let offsetY = displayFrame.maxY - region.maxY
        let startRegion = region

        Task { @MainActor [weak self] in
            guard let self else { return }
            let lines = await VisionTextRecognition().recognize(in: image)
            guard self.model.confirmedRect == startRegion, !lines.isEmpty else { return }
            let rects = lines.map { line in
                CGRect(
                    x: offsetX + line.rect.minX / scale,
                    y: offsetY + line.rect.minY / scale,
                    width: line.rect.width / scale,
                    height: line.rect.height / scale
                )
            }
            self.annotation.addAutoMosaic(in: rects, pixelSource: { [weak self] rect in
                self?.frozenPixels(rect)
            })
            self.redraw()
        }
    }

    /// ⌥+单击的整窗捕获出口。`image` 放冻结画面上窗口可见部分的裁剪 ——
    /// 协调器异步用 SCK 重拍完整窗口，只有窗口已经消失时才落回这份兜底。
    /// gesture target 经 `OverlayGestureHost` 调它，不能 private。
    func emitFullWindow(_ window: WindowInfo) {
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

// MARK: - OverlayGestureHost conformance
//
// 其余成员（model/annotation/slots/emit/…）都是本类既有 API，
// 这里只补 target 需要、而视图还没有的窄门面成员。

extension OverlayView: OverlayGestureHost {

    func becameActive() {
        onBecameActive?(self)
    }

    var selectionAIHostIsActive: Bool { selectionAIHost.isActive }

    func hasLiveTextInteractiveItem(atViewLocal local: CGPoint) -> Bool {
        guard let overlay = liveTextHost.overlay else { return false }
        return overlay.hasInteractiveItem(at: overlay.convert(local, from: self))
    }
}

// LiveTextHitTestView 已移至 OverlayView+LiveText.swift，与 LiveTextOverlayHost 同处。
