import SwiftUI
import AppKit
import VisionKit

/// 图库窗口的 contentView 包装层。override `hitTest` 把「选字」鼠标事件
/// 路由给系统 Live Text 层。
///
/// 编辑器画布嵌在 SwiftUI 层级里：包着 LayerCanvas 的 `NSHostingView` 因为
/// 上面压着 `DragGesture(minimumDistance: 0)`，它的 hitTest 对画布上的所有点
/// 都返回自己 —— AppKit 的 mouseDown 永远到不了下面的
/// `ImageAnalysisOverlayView`（表现为 I-beam 出现但拖不出选区；钉图窗口是
/// 纯 AppKit，没有这一层，所以一直正常）。
///
/// 窗口派发鼠标事件时从 contentView 的 hitTest 链开始。这个包装层就是
/// contentView，在链的第一站短路返回 overlay，整条 hosting view 链被绕开。
/// 命中判定与 CanvasView.hitTest 同一份口径（`liveTextHitView`），
/// 不命中时走 `super.hitTest`，SwiftUI 手势不受影响。
/// mouseDown 一旦派发给 overlay，同一次点击的 mouseDragged/mouseUp 会
/// 粘性地继续发给它（AppKit 对点击序列的事件路由），拖选跨出文字区也不断。
final class LiveTextRoutingView: NSView {

    /// 当前编辑器画布。弱引用：画布随编辑会话创建/销毁，viewDidMoveToWindow 时更新。
    weak var liveTextCanvas: CanvasView?

    override func hitTest(_ point: NSPoint) -> NSView? {
        // 只对**点击序列**（down / dragged / up）路由给系统选字层。
        // mouseMoved 不路由：系统层会自己管理光标（依赖那个时灵时不灵的
        // hasInteractiveItem），一旦接管就会覆盖 SwiftUI hover 里设的 I-beam。
        // 光标控制交给 SwiftUI 的 onContinuousHover（用确定性的 OCR 框判定）。
        // 无事件上下文的 hitTest（窗口移动、视图更新等）也不路由，走原路径。
        guard let type = NSApp.currentEvent?.type,
              type == .leftMouseDown || type == .leftMouseDragged || type == .leftMouseUp
        else {
            return super.hitTest(point)
        }
        // 包装层是 contentView，自身坐标系与窗口坐标系一致（原点都在
        // 内容区左下角），point 可直接按窗口坐标交给画布换算。
        if let hit = liveTextCanvas?.liveTextHitView(atWindowPoint: point) {
            return hit
        }
        return super.hitTest(point)
    }
}

/// 图层画布。底图 + 图层，用**和导出完全相同**的那段绘制代码渲染。
///
/// 此前编辑器用 SwiftUI `Canvas` 手写了一套近似渲染（箭头、文字都是重写的），
/// 与 `LayerRenderer` 不保证一致 —— 这是「所见非所得」的直接来源。
/// 现在编辑器、截图覆盖层、钉图窗口三处的预览都走 `AnnotationRenderer`。
struct LayerCanvas: NSViewRepresentable {

    /// 截图 ID。只用于 Live Text 分析的进程级缓存键 —— 同一张截图
    /// 再次打开编辑器时复用上一份 `ImageAnalysis`，跳过重新推理与死区。
    var shotID: Int64?
    /// 底图，已应用提交过的马赛克。
    let image: CGImage
    /// 要绘制的图层，图像像素空间。
    let layers: Layers<ImageSpace>
    /// 正在拖的马赛克没有预算好的贴片，渲染器会画灰块占位。
    let pixelatePreviews: [UUID: CGImage]
    let selectedLayerID: UUID?
    /// 画布实例创建后回传引用，供外部调 `copyLiveTextSelection()` 等。
    var onCreated: ((CanvasView) -> Void)?
    /// 点是否落在某个标注图层上（图像像素坐标，左上原点）。
    /// 由宿主注入 `annotation.layer(at:)` —— 与 SwiftUI 手势同一份命中口径，
    /// 保证「事件给了谁」和「拖出来的是标注还是选字」永远一致。
    var layerHitTest: ((CGPoint) -> Bool)?

    func makeNSView(context: Context) -> CanvasView {
        let view = CanvasView()
        onCreated?(view)
        return view
    }

    func updateNSView(_ view: CanvasView, context: Context) {
        view.shotID = shotID
        view.image = image
        view.layers = layers
        view.pixelatePreviews = pixelatePreviews
        view.selectedLayerID = selectedLayerID
        view.layerHitTest = layerHitTest
        view.needsDisplay = true
        // 底图换了要重跑分析（占位图 → 真图解码完成、马赛克重烤都会换引用）。
        view.syncLiveTextAnalysisIfNeeded()
    }
}

/// 一次 Live Text 分析请求：输入图 + 进程级缓存键 + 任务。
/// 键在**发起时**算好并随请求保存，落地时直接用 —— 分析期间换图会触发
/// 新请求（代数自增），旧结果被代数守卫丢弃，键不会跟着漂移。
private struct LiveTextPending {
    let image: CGImage
    let shotID: Int64?
    /// 底图像素尺寸。占位图（1×1）与真图由此区分，不会互相命中。
    let size: CGSize
    /// 马赛克图层。打了码的字不该还能选出来 —— 它改变了分析输入，必须参与判等。
    let pixelates: Layers<ImageSpace>
    /// 系统分析任务：给 overlay 做实际拖选高亮 + ⌘C 复制。
    /// 命中判定不靠它 —— 那用 `ocrRects`（独立 OCR 任务产出，落地即可用），
    /// 不依赖 VisionKit 那个时灵时不灵的 `hasInteractiveItem`。
    let task: Task<ImageAnalysis?, Never>
}

final class CanvasView: NSView {

    /// 截图 ID，由 LayerCanvas 注入。nil（无主图场景）时不参与进程级缓存。
    var shotID: Int64?
    var image: CGImage?
    var layers = Layers<ImageSpace>()
    var pixelatePreviews: [UUID: CGImage] = [:]
    var selectedLayerID: UUID?
    /// 点是否落在某个标注图层上（图像像素坐标，左上原点）。见 LayerCanvas.layerHitTest。
    var layerHitTest: ((CGPoint) -> Bool)?

    // MARK: - Live Text（与钉图同一模式：归一化坐标、hitTest 分流）

    private(set) var isLiveTextActive = false
    private var liveTextOverlay: ImageAnalysisOverlayView?
    /// 缓存键是 image 引用本身：占位图 → 真图解码完成 → 马赛克重烤，
    /// 任何一种换图都必须重跑分析（曾只用马赛克图层做键，占位图的分析
    /// 结果一直留着，表现为「文字永远选不中」）。
    private var liveTextAnalysis: LiveTextPending?
    /// 分析代数。每次起新任务自增；落地闭包捕获发起时的值，
    /// 落地时不一致说明已有更新的任务在跑 —— 迟到的旧结果直接丢弃
    /// （VisionKit 推理不响应 Task.cancel，占位图的空结果可能晚于真图落地）。
    private var liveTextGeneration = 0
    /// 当前已绑定到 overlay 的 analysis 实例。用于**去重**：
    /// updateNSView / layout 每次都会安排一次「稍后重绑 analysis」，
    /// 而反复给 overlay 赋同一个 analysis 会重置它的内部交互状态，
    /// 把正在进行中的拖选打断（表现为「有时能选中有时不能」——
    /// 全看拖选期间有没有恰好一次冗余重绑定落地）。
    private var appliedAnalysis: ImageAnalysis?
    /// 自己的 OCR 文字框（图像像素坐标、左上原点）。命中判定用它：
    /// 确定、立即可用，不依赖 VisionKit 的 `hasInteractiveItem`。
    /// 分析落地时写入；换图（新 pending）时先清空，避免用旧图的框判新图。
    private var ocrRects: [CGRect] = []
    /// 有「已发起未落地」的分析任务。`applyLiveTextAnalysis` 据此决定要不要
    /// 安排落地闭包 —— 落地后清掉，updateNSView / layout 的反复调用不再空跑。
    private var pendingApply = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // 注册到窗口 contentView 的 Live Text 路由：它是事件派发链的第一站，
        // 在这里短路返回 overlay 才能绕开 NSHostingView 的 DragGesture 拦截。
        (window?.contentView as? LiveTextRoutingView)?.liveTextCanvas = self
        if window != nil, !isLiveTextActive, LiveTextAnalyzer.isSupported {
            enterLiveText()
        }
    }

    deinit {
        liveTextAnalysis?.task.cancel()
    }

    /// 进入选字：挂系统层、跑分析。指针模式下文字上拖=选字，空白处行为不变。
    func enterLiveText() {
        guard !isLiveTextActive else { return }
        isLiveTextActive = true
        prepareLiveTextAnalysis()

        let overlay = ImageAnalysisOverlayView()
        overlay.preferredInteractionTypes = [.textSelection]
        overlay.frame = bounds
        addSubview(overlay)
        liveTextOverlay = overlay
        applyLiveTextAnalysis()
        needsDisplay = true
    }

    /// ⌘C：有选中文字就复制文字。返回是否已处理。
    func copyLiveTextSelection() -> Bool {
        guard let overlay = liveTextOverlay, overlay.hasActiveTextSelection else { return false }
        Clipboard.copy(text: overlay.selectedText)
        return true
    }

    /// 判断某点（视图本地坐标）是否落在可交互文字上，**且不在任何标注图层上**。
    /// 标注图层是显式对象、优先于背景里被动识别出的文字 —— 自己的文字图层压在
    /// 识别文字上时，点它应该是选中/拖动图层，而不是拖出一段背景选字。
    ///
    /// 命中判定用**自己的 OCR 文字框**（`ocrRects`，图像像素坐标、左上原点），
    /// 不用 VisionKit 的 `hasInteractiveItem` —— 后者绑定 analysis 后还要数秒到
    /// 十余秒才建好词级空间索引，期间恒为 false，是「时灵时不灵」的根源。
    /// OCR 框落地即可用、确定，外扩 2 像素让点字更容易命中（OCR 框偏紧）。
    func hasLiveTextInteractiveItem(atViewLocal local: CGPoint) -> Bool {
        guard isLiveTextActive, liveTextOverlay != nil else { return false }
        if layerHitTest?(imagePixelPoint(fromViewLocal: local)) == true { return false }
        let pixel = imagePixelPoint(fromViewLocal: local)
        return ocrRects.contains { $0.insetBy(dx: -2, dy: -2).contains(pixel) }
    }

    /// 视图本地坐标 → 图像像素坐标（左上原点），与 draw / SwiftUI 手势同一换算。
    private func imagePixelPoint(fromViewLocal local: CGPoint) -> CGPoint {
        guard let image, bounds.width > 0 else { return .zero }
        let scale = bounds.width / CGFloat(image.width)
        return CGPoint(x: local.x / scale, y: (bounds.height - local.y) / scale)
    }

    // MARK: 分析任务

    private func prepareLiveTextAnalysis() {
        guard let image else { return }
        if let cached = liveTextAnalysis, cached.image === image { return }
        liveTextAnalysis?.task.cancel()
        liveTextGeneration += 1
        pendingApply = true
        // 换图先清旧框：新图的分析落地前，命中判定用不到（空数组 = 不命中），
        // 避免拿旧图的框判新图。
        ocrRects = []

        let pixelates = layers.filter { $0.kind == .pixelate }
        let size = CGSize(width: image.width, height: image.height)
        let generation = liveTextGeneration

        if let shotID,
           let hit = LiveTextAnalysisCache.lookup(shotID: shotID, size: size, pixelates: pixelates) {
            // 进程级缓存命中（同一张截图、同一底图尺寸、同一组马赛克）：
            // 复用上一份结果，推理直接跳过。OCR 框也立刻可用。
            ocrRects = hit.ocrRects
            liveTextAnalysis = LiveTextPending(
                image: image, shotID: shotID, size: size, pixelates: pixelates,
                task: Task { hit.analysis }
            )
        } else {
            // 非缓存：OCR 独立跑，落地就写 ocrRects（命中判定立刻可用），
            // 不等 VisionKit 分析（那路只给 overlay 做拖选高亮，较慢）。
            // 推理在后台线程，落地闭包回主线程写 NSView 属性。
            Task { @MainActor [weak self] in
                let lines = await VisionTextRecognition().recognize(in: image)
                guard let self, self.liveTextGeneration == generation,
                      self.liveTextAnalysis?.image === image else { return }
                self.ocrRects = lines.map(\.rect)
                // 若 analysis 已绑定，把 OCR 框补进缓存（覆盖分析落地时写的空框）。
                if let analysis = self.appliedAnalysis,
                   let pending = self.liveTextAnalysis,
                   pending.image === self.image, let shotID = pending.shotID {
                    LiveTextAnalysisCache.store(
                        shotID: shotID, size: pending.size,
                        pixelates: pending.pixelates, analysis: analysis,
                        ocrRects: self.ocrRects
                    )
                }
            }
            liveTextAnalysis = LiveTextPending(
                image: image, shotID: shotID, size: size, pixelates: pixelates,
                task: Task { await LiveTextAnalyzer.analyze(image) }
            )
        }
    }

    /// 由 updateNSView 调用：底图换了才取消重跑（占位图 → 真图解码完成、
    /// 马赛克重烤都会换引用）。同一张图的反复重绘不重跑。
    func syncLiveTextAnalysisIfNeeded() {
        guard isLiveTextActive else { return }
        prepareLiveTextAnalysis()
        applyLiveTextAnalysis()
    }

    private func applyLiveTextAnalysis() {
        // 没有「已发起未落地」的任务就不安排 —— updateNSView / layout 每次
        // 都会走到这里，稳态下空跑 Task 只是浪费。
        guard pendingApply else { return }
        pendingApply = false
        let task = liveTextAnalysis?.task
        let generation = liveTextGeneration
        Task { @MainActor [weak self, weak overlay = liveTextOverlay] in
            let analysis = await task?.value
            // `generation == 当前代数`：换图时起新任务并自增代数，但 VisionKit
            // 推理不响应 Task.cancel —— 占位图的空结果可能**晚于**真图落地，
            // 把 overlay 覆盖成「没有字」，之后怎么拖都选不中（每次落点抽签，
            // 表现为时灵时不灵）。迟到的旧代数一律丢弃。
            guard let self, let overlay,
                  self.isLiveTextActive, overlay === self.liveTextOverlay,
                  self.liveTextGeneration == generation else { return }
            // 同一个 analysis 只绑一次：重复给 overlay 赋同一个 analysis
            // 会重置它的内部交互状态，把正在进行中的拖选打断。
            if self.appliedAnalysis !== analysis {
                self.appliedAnalysis = analysis
                // 非空结果写进进程级缓存：同一张截图再次打开编辑器时
                // prepareLiveTextAnalysis 直接命中，跳过重新推理。
                // OCR 框此刻可能还没落地（独立任务），先写当前值；
                // OCR 落地后会再补一次（见 prepareLiveTextAnalysis 的独立任务）。
                if let analysis, let pending = self.liveTextAnalysis,
                   pending.image === self.image, let shotID = pending.shotID {
                    LiveTextAnalysisCache.store(
                        shotID: shotID, size: pending.size,
                        pixelates: pending.pixelates, analysis: analysis,
                        ocrRects: self.ocrRects
                    )
                }
                overlay.analysis = analysis
            }
        }
    }

    // MARK: - 事件
    //
    // 与钉图完全同构：**只做 hitTest 分流，绝不手动 forward**。
    //   · 命中可拖选文字 → 返回 overlay，AppKit 原生把 mouseDown/dragged/up/
    //     右键全部派发给系统层（I-beam、拖选高亮、双击选词、服务菜单）。
    //     事件目标变成 overlay 后，上层 NSHostingView 收不到 mouseDown，
    //     SwiftUI 的 DragGesture 因此不会同时触发（天然互斥）。
    //   · 空白处 → 返回 nil，事件绕过本视图直达 SwiftUI，标注/选中行为不变。
    //
    // 曾经在这里手动 overlay.mouseDown/mouseDragged/mouseUp/mouseMoved 转发
    // 「双保险」—— 但 AppKit 本就按 hitTest 自动路由，两条路由叠加成
    // forwardMethod 无限递归（511 帧崩溃，死在 TextRecognition 野指针）。

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isLiveTextActive, let overlay = liveTextOverlay else { return nil }
        let local = convert(point, from: superview)
        guard bounds.contains(local),
              overlay.bounds.contains(overlay.convert(local, from: self)),
              hasLiveTextInteractiveItem(atViewLocal: local) else { return nil }
        return overlay.hitTest(overlay.convert(local, from: self)) ?? overlay
    }

    /// 窗口级路由入口（`LiveTextRoutingWindow.hitTest` 调用）：
    /// 点为**窗口坐标**。换算到视图本地后走与 `hitTest` 同一份命中口径。
    /// 返回非 nil = 「这次点击归系统选字层」—— 窗口 hitTest 直接短路返回它，
    /// 绕开 NSHostingView 的 DragGesture 拦截（见 LiveTextRoutingWindow 注释）。
    func liveTextHitView(atWindowPoint point: NSPoint) -> NSView? {
        guard isLiveTextActive, let overlay = liveTextOverlay else { return nil }
        let local = convert(point, from: nil)
        guard bounds.contains(local),
              overlay.bounds.contains(overlay.convert(local, from: self)),
              hasLiveTextInteractiveItem(atViewLocal: local) else { return nil }
        return overlay.hitTest(overlay.convert(local, from: self)) ?? overlay
    }

    override func layout() {
        super.layout()
        liveTextOverlay?.frame = bounds
        // 缩放后重新绑定已有分析（钉图同款）：归一化坐标不用重跑 OCR，
        // 但不重绑的话 hasInteractiveItem 在首帧会误判为空白。
        // applyLiveTextAnalysis 内部有 pendingApply 守卫，稳态下是空操作。
        if isLiveTextActive { applyLiveTextAnalysis() }
    }

    // MARK: - 绘制

    override func draw(_ dirtyRect: NSRect) {
        guard let image, let ctx = NSGraphicsContext.current?.cgContext else { return }
        guard bounds.width > 0, image.width > 0 else { return }

        ctx.interpolationQuality = .high
        ctx.draw(image, in: bounds)

        let scale = bounds.width / CGFloat(image.width)

        ctx.saveGState()
        // 翻成「图像像素、左上原点、Y 向下」—— 和图层坐标系一致。
        ctx.translateBy(x: 0, y: bounds.height)
        ctx.scaleBy(x: scale, y: -scale)
        AnnotationRenderer.draw(layers, pixelatePreviews: pixelatePreviews, in: ctx)
        // 选中框 + 缩放控制点走覆盖层/钉图同一份绘制；strokeScale 反除显示倍率，
        // 虚线和控制点在屏幕上恒定 1pt / 7pt。
        AnnotationRenderer.drawSelectionHint(
            selectedID: selectedLayerID,
            layers: layers,
            strokeScale: 1 / max(scale, 0.0001),
            in: ctx
        )
        ctx.restoreGState()
    }
}
