import AppKit
import Combine
import SwiftUI

// MARK: - 编辑器的共享状态
//
// 编辑器被切成了工具栏 / 画布 / 效果面板 / 图层面板 / 底栏五块，
// 这里装它们**都要看到**的那部分状态与逻辑：底图、缩放、修订链、自动保存。
//
// 只属于某一块的状态不放这儿 —— 画布的拖拽阶段、平移位置、空格监视器留在画布，
// 面板的 tab 留在面板。判据很简单：**只有一处读写的，就不是共享状态。**
//
// 为什么需要它：拆之前这些全是 `EditorView` 的 `@State`，子视图够不到；
// 硬拆就得把十几个 `Binding` 一路传下去，那比不拆还糟。
@MainActor
final class EditorModel: ObservableObject {

    let shot: Shot
    /// 标注状态机。它自己是 ObservableObject —— 子视图直接订阅它，
    /// 不必经由本模型转发（转发等于把每个变更抄两遍）。
    let annotation: AnnotationState

    private let store: ShotStore
    private let styleStore: any AnnotationStylePreferences

    // MARK: 图像

    @Published private(set) var baseImage: CGImage?
    /// 底图 + 已应用的马赛克。拖拽过程中不重算，只在图层提交后刷新。
    @Published private(set) var canvasImage: CGImage?

    // MARK: 视口

    /// 画布缩放倍率。`nil` = 适应窗口；非 nil 时画布尺寸 = 图像点尺寸 × 倍率。
    @Published var zoomLevel: Double?
    /// 画布模式：指针（画/选/移图层）或抓手（拖拽平移视口）。
    /// 抓手**不是**标注工具（不进 `AnnotationTool`）—— 覆盖层/钉图没有滚动概念。
    @Published var canvasMode: CanvasMode = .pointer
    /// 滚动容器的命令桥：抓手平移、锚点缩放都经它摸 NSClipView。
    /// 画布装配它，工具栏的缩放控件也要用（⌘0 适应窗口），所以是共享的。
    let panBox = CanvasPanBox()

    enum CanvasMode { case pointer, hand }

    /// 右侧文字框是否有焦点。**工具栏要看它** —— 打字时裸键快捷键（R / A / …）
    /// 必须让位。焦点本身是面板里的 `@FocusState`，这里只是它的镜像。
    @Published var isTextFieldFocused = false

    // MARK: 修订与保存

    @Published private(set) var revisions: [Revision] = []
    @Published private(set) var loadedRevisionIndex: Int?
    /// 已落库的那一版图层。自动保存靠它和当前画布做**内容比对** ——
    /// 「画一笔再撤销」回到原样时不会留下一条空修订。
    @Published private(set) var baselineLayers: [Layer] = []
    /// 最近一次落库的时刻。底栏那行状态字用它。
    @Published private(set) var savedAt: Date?

    private var autoSaveTask: Task<Void, Never>?
    private var annotationSubscription: AnyCancellable?

    init(shot: Shot, store: ShotStore = .shared, styleStore: any AnnotationStylePreferences) {
        self.shot = shot
        self.store = store
        self.styleStore = styleStore
        self.annotation = AnnotationState(styleStore: styleStore)
        annotationSubscription = annotation.objectWillChange.sink { [weak self] _ in
            // ⚠️ **必须转发**。视图观察的是 model，而 `annotation` 只是模型上的一个
            // 普通 `let` —— 它自己发的变更不会让任何 SwiftUI 视图失效。
            // 漏掉这一行的后果是：画的时候画布不重绘，笔画要等到 1.2 秒后
            // 自动保存写了 @Published 属性才顺带刷出来，用起来就是「特别卡」。
            // （这是把状态从视图搬进模型时最容易掉的一环：搬走了持有者，
            //   就得接上观察链。）
            self?.objectWillChange.send()

            // 标注一变就重新计时。此前这是视图上的 `.onChange(of: annotationTick)`，
            // 意味着「忘了 +1 的地方连自动保存也不会触发」。
            self?.scheduleAutoSave()
        }
    }

    // MARK: - 加载

    func load() {
        guard let base = store.originalImage(for: shot) else { return }
        baseImage = base
        // 效果层的注入上下文（编辑器这一处，与覆盖层/钉图同一契约）：
        // 画布就是图像像素 —— 水印按原图宽烤字号、壳/信息栏按 shot.scale 缩放；
        // 元数据来自采集时落库的真实归因 —— 竞品的壳是空的，这里是真的。
        annotation.effectContext = { [shot, styleStore] in
            var context = EffectContext()
            context.imagePixelWidth = Double(base.width)
            context.imagePixelHeight = Double(base.height)
            context.chromeScale = max(1, shot.scale)
            context.windowTitle = shot.windowTitle
            context.sourceURL = shot.sourceURL
            context.appDescription = CaptureInfoSpec.appDescription(
                name: shot.appName, version: shot.appVersion
            )
            context.capturedAt = shot.capturedAt
            context.watermarkText = styleStore.watermarkText
            context.watermarkMode = styleStore.watermarkMode
            context.watermarkAlpha = styleStore.watermarkAlpha
            context.backdropPaddingRatio = styleStore.backdropPaddingRatio
            context.backdropCornerRatio = styleStore.backdropCornerRatio
            context.backdropShadowRatio = styleStore.backdropShadowRatio
            context.backdropShadowAlpha = styleStore.backdropShadowAlpha
            return context
        }
        revisions = store.revisions(for: shot)
        loadRevision(layers: revisions.last?.layers ?? [], index: max(0, revisions.count - 1))
    }

    /// 载入某一版历史（图层面板的版本列表用）。
    func loadRevision(layers: [Layer], index: Int) {
        annotation.load(Layers(persisted: layers), pixelSource: cropPixels)
        baselineLayers = layers
        loadedRevisionIndex = index
        refreshCanvasImage()
    }

    /// 马赛克贴片的像素来源：编辑器画布就是图片像素，直接从原图裁。
    func cropPixels(_ rect: CGRect) -> CGImage? {
        baseImage?.cropping(to: rect.integral)
    }

    /// 只有马赛克需要走像素管线，这里单独重算一次。
    func refreshCanvasImage() {
        guard let base = baseImage else { return }
        let pixelates = exportedLayers.filter { $0.kind == .pixelate }
        canvasImage = pixelates.isEmpty
            ? base
            : LayerRenderer.render(base: base, layers: pixelates)
    }

    /// 恒等投影到图像像素空间 —— 入库、导出、烤底图都用这一份。
    var exportedLayers: Layers<ImageSpace> {
        annotation.layers.projected(onto: .zero, scale: 1)
    }

    func rendered() -> CGImage? {
        guard let base = baseImage else { return nil }
        return LayerRenderer.render(base: base, layers: exportedLayers)
    }

    // MARK: - 撤销 / 重做 / 删除
    //
    // 都要跟一次 `refreshCanvasImage()` —— 马赛克的底图是烤出来的，
    // 图层变了不重算的话画布上会留着上一版的马赛克。

    func undo() {
        guard annotation.undo() else { return }
        refreshCanvasImage()
    }

    func redo() {
        guard annotation.redo() else { return }
        refreshCanvasImage()
    }

    func deleteSelected() {
        guard annotation.deleteSelected() else { return }
        refreshCanvasImage()
    }

    // MARK: - 自动保存
    //
    // 编辑器**不需要手动保存**。此前离开画布时会弹「有未保存的标注，仍要离开吗？」
    // 三选一对话框 —— 非破坏式编辑下每次保存只是往修订链追加一条、原图从不改动，
    // 没有任何「保存失败会毁掉东西」的风险，却要求用户每次离开都做一次决定。
    //
    // 节流 1.2 秒：画的过程中每一笔都会发变更，逐笔落库会把修订链撑成流水账；
    // 停下来一会儿才算「改完了」。离开画布时**立即冲一次**，不等节流。

    private static let autoSaveDelay: Duration = .milliseconds(1200)

    func scheduleAutoSave() {
        autoSaveTask?.cancel()
        autoSaveTask = Task { [weak self] in
            try? await Task.sleep(for: Self.autoSaveDelay)
            guard !Task.isCancelled else { return }
            self?.flushSave()
        }
    }

    /// 立即落库。没有实际改动时什么都不做 —— 内容比对（而不是图层数量比对）
    /// 保证「画一笔再撤销」不会留下一条空修订。
    func flushSave() {
        autoSaveTask?.cancel()
        autoSaveTask = nil
        annotation.endTextEditing()

        let layers = exportedLayers
        guard layers.persisted != baselineLayers else { return }

        store.appendRevision(
            shot: shot,
            layers: layers,
            note: "编辑 \(annotation.layers.count) 层"
        )
        revisions = store.revisions(for: shot)
        loadedRevisionIndex = revisions.count - 1
        baselineLayers = layers.persisted
        savedAt = Date()
    }

    /// 有改动还没落库。底栏的状态字用它。
    var hasPendingChanges: Bool {
        // 先比数量再比内容：底栏那行状态字**每次重绘都会问一次**，
        // 而拖拽时重绘是每帧的。数量不等就能立刻定论，省掉一次整数组的
        // 投影 + 逐层比较；数量相等才走精确比对（「改了颜色但层数没变」要认得出来）。
        let layers = annotation.layers
        if layers.count != baselineLayers.count { return true }
        return exportedLayers.persisted != baselineLayers
    }

    // MARK: - 导航
    //
    // 换图与返回图库都**先落库再走**，不再有「未保存」这个状态。

    func requestReturnToGallery() {
        flushSave()
        GalleryWindowController.shared.mode.returnToGallery()
    }
}
