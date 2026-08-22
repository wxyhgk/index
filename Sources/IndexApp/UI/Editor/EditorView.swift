import SwiftUI
import AppKit

/// 画布 NSView 的引用容器。LayerCanvas 是 NSViewRepresentable，NSView 实例
/// 只能在 makeNSView 里拿到 —— 用闭包回传存到这里，⌘C / 悬停让位才能摸到它。
final class CanvasHolder {
    var view: CanvasView?
}

/// 稳定外壳与当前编辑会话之间唯一的一条命令通道。
///
/// Filmstrip 已经移到会话 `.id` 之外，但切图仍必须保持原来的“先落库再换图”顺序。
/// relay 只暂存当前会话的 flush 闭包；shot ID 校验防止旧会话的 onDisappear 清掉
/// 刚安装的新会话。
@MainActor
final class EditorSessionRelay: ObservableObject {
    private var shotID: Int64?
    private var flushAction: (() -> Void)?

    func install(shotID: Int64?, flush: @escaping () -> Void) {
        self.shotID = shotID
        flushAction = flush
    }

    func flush(shotID: Int64?) {
        guard self.shotID == shotID else { return }
        flushAction?()
    }

    func remove(shotID: Int64?) {
        guard self.shotID == shotID else { return }
        self.shotID = nil
        flushAction = nil
    }
}

/// 编辑模式的稳定外壳。
///
/// 只有真正依赖 `shot` 的编辑会话按 ID 重建；Filmstrip 留在外面保持自己的
/// 横向滚动位置。此前 `.id(shot.id)` 套在整个 `EditorView` 上，点一张缩略图会把
/// Filmstrip 一起销毁，再从空数组加载并把当前项强制居中，看起来就像其它图片消失。
struct EditorModeView: View {
    let shot: Shot
    let styleStore: any AnnotationStylePreferences
    @StateObject private var sessionRelay = EditorSessionRelay()

    var body: some View {
        VStack(spacing: 0) {
            EditorView(shot: shot, sessionRelay: sessionRelay, styleStore: styleStore)
                .id(shot.id)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            EditorFilmstrip(
                currentShotID: shot.id,
                onSelect: switchEditor
            )
            .equatable()
        }
        .frame(minWidth: 900, minHeight: 620)
    }

    private func switchEditor(to target: Shot) {
        guard target.id != shot.id else { return }
        sessionRelay.flush(shotID: shot.id)
        GalleryWindowController.shared.mode.openEditor(shotID: target.id)
    }
}

/// 非破坏性标注编辑器。
/// 画布上的一切都是图层；保存时只是往 revision 表追加一条记录，原图字节永远不变。
///
/// 活在**图库窗口内**（Snagit 的 Editor/Library 单窗口双模式）：
/// `GalleryWindowMode.editingShotID` 非 nil 时 GalleryView 按 ID 现查 Shot
/// 并整窗切到本视图，返回图库 = `returnToGallery()`；换图 = 换成目标 ID
/// （宿主用 `.id(shot.id)` 保证重建，`shot` 因此得以保持 `let`，
/// 重新走一遍 onAppear → load）。
///
/// 状态机是和截图覆盖层 / 钉图窗口**同一个** `AnnotationState` ——
/// 工具、固定 4 色 3 档粗细、选中 / 拖动 / 删除、全量撤销重做因此完全一致。
/// 编辑器的画布空间就是图片像素（和钉图一样），`CanvasSpace ↔ ImageSpace` 是恒等变换。
struct EditorView: View {

    let shot: Shot

    // 视图**不再直接碰数据库** —— 读写全在 `EditorModel` 里。
    // （它也刻意不订阅 store：后台 OCR 回填会触发发布，没必要为此重建整个编辑器。）

    /// 编辑器的共享状态：底图、缩放、修订链、自动保存 —— 各块子视图都要看到的那部分。
    /// 只属于某一块的（画布的拖拽阶段、平移位置、面板的 tab）不放进去。
    @StateObject private var model: EditorModel
    private let sessionRelay: EditorSessionRelay?

    /// 标注状态机。真正的持有者是 model，这里只是个转发，省得满篇 `model.annotation`。
    private var annotation: AnnotationState { model.annotation }

    init(shot: Shot, sessionRelay: EditorSessionRelay? = nil, styleStore: any AnnotationStylePreferences) {
        self.shot = shot
        self.sessionRelay = sessionRelay
        _model = StateObject(wrappedValue: EditorModel(shot: shot, styleStore: styleStore))
    }

    /// 一次画布拖拽在做什么。`idle` 表示这次按下不产生后续（点空处取消选中等）。
    private enum CanvasDrag { case draw, move, resize, idle }
    @State private var canvasDrag: CanvasDrag?

    /// 缩放菜单的固定档位。⌃滚轮 / 捏合走连续缩放，范围见 `zoomRange`。
    private static let zoomSteps: [Double] = [0.25, 0.5, 1, 2, 4]

    /// 连续缩放的钳制范围。
    private static let zoomRange: ClosedRange<Double> = 0.1...8.0

    /// 抓手拖拽的上一次光标位置（窗口坐标 —— 平移时内容在光标下滑动，
    /// 本地坐标会跟着变，只有窗口坐标是稳定参照）。nil = 没在拖。
    @State private var panLastWindowLocation: CGPoint?

    /// 光标是否悬在画布上（空格临时抓手切换光标样式时用）。
    @State private var canvasHovered = false

    /// 按住空格临时抓手的按键监视器。
    @StateObject private var spaceMonitor = EditorSpaceHandMonitor()

    /// 中键拖拽平移画布（放大后不用空格也能挪）。
    @StateObject private var middlePanMonitor = EditorMiddlePanMonitor()

    /// 画布实例引用（LayerCanvas.onCreated 回传）。选字层的 ⌘C / 悬停让位要用它。
    @State private var canvasHolder = CanvasHolder()

    /// 右侧文字框获得焦点时，裸键工具快捷键（R / A / …）必须让位给打字。
    @FocusState private var textFieldFocused: Bool

    /// 编辑器工具栏的展示顺序。`nil` 是指针模式。
    private static let toolOrder: [AnnotationTool?] =
        [nil, .rect, .ellipse, .arrow, .line, .text, .counter, .highlight, .spotlight,
         .dimension, .pixelate, .crop]

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            HStack(spacing: 0) {
                canvas
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .underPageBackgroundColor))
                Divider()
                inspector
                    .frame(width: 260)
            }
            Divider()
            bottomBar
        }
        .background(hiddenShortcuts)
        .onAppear {
            model.load()
            spaceMonitor.install()
            middlePanMonitor.scrollBy = { model.panBox.scrollBy(dx: $0, dy: $1) }
            middlePanMonitor.isOverCanvas = { model.panBox.containsWindowPoint($0) }
            middlePanMonitor.install()
            sessionRelay?.install(shotID: shot.id) { model.flushSave() }
        }
        .onDisappear {
            spaceMonitor.remove()
            middlePanMonitor.remove()
            // 视图消失（换图重建、窗口关闭、切到别的顶层选项）时**立即**落库，
            // 不等节流 —— 节流任务会随视图一起没掉，等不到它自己触发。
            model.flushSave()
            sessionRelay?.remove(shotID: shot.id)
        }
        .onChange(of: model.zoomLevel) { _, newValue in
            if newValue == nil {
                // 回到适应态：内容 3× 视口、图片居中，把视口滚回内容中心，
                // 图片落在视口正中（观感与缩放前一致）。
                model.panBox.centerOnNextUpdate = true
                // 抓手模式随之退场（按钮也已置灰）。
                model.canvasMode = .pointer
            }
        }
        .onChange(of: spaceMonitor.spaceHeld) { _, held in
            // 空格切手势会让进行中的标注拖拽收不到 onEnded，主动收尾避免状态卡住。
            if held, canvasDrag != nil { handleDragEnded() }
            if !held { panLastWindowLocation = nil }
            if canvasHovered {
                (handModeActive ? NSCursor.openHand : NSCursor.arrow).set()
            }
        }
    }

    // MARK: - 加载

    // 加载、按版本载入、马赛克像素源、画布底图重算、导出投影
    // 全部搬进了 `EditorModel` —— 它们是数据，不是视图。

    // MARK: - 工具栏（已抽至 EditorToolbar.swift）

    private var toolbar: some View {
        EditorToolbar(
            annotation: annotation,
            model: model,
            textFieldFocused: $textFieldFocused
        )
    }

    // 效果面板（美化 / 水印 / 外壳 / 捕获信息）已搬到 `EditorEffectsPanel`。

    /// 不可见按钮承载的快捷键：⌫ 删除选中图层（打字时禁用，退格让给文字框）、
    /// ⌘C 复制（选字层有选中文字就复制文字，否则复制成品图）、
    /// ⌘0 适应窗口、⌘+ 放大（⌘= 挂在底栏的加号按钮上，这里补真正的 "+" 键）。
    private var hiddenShortcuts: some View {
        Group {
            Button("删除选中图层") { model.deleteSelected() }
                .keyboardShortcut(.delete, modifiers: [])
                .disabled(textFieldFocused || annotation.selectedID == nil)
            // 与钉图 / 截图覆盖层同一口径：选字层优先，没选中文字才复制图。
            Button("复制") {
                let copiedText = canvasHolder.view?.copyLiveTextSelection() ?? false
                if !copiedText { copyRendered() }
            }
            .keyboardShortcut("c", modifiers: .command)
            .disabled(textFieldFocused)
            Button("适应窗口") { model.zoomLevel = nil }
                .keyboardShortcut("0", modifiers: .command)
            Button("放大") { zoomIn() }
                .keyboardShortcut("+", modifiers: .command)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    // MARK: - 操作

    // 撤销 / 重做 / 删除都搬进了 `EditorModel` —— 它们各自要跟一次画布底图重算
    // （马赛克的底图是烤出来的，图层变了不重算就会留着上一版）。

    // MARK: - 画布

    /// 两种布局态共用一条 `canvasBody` 修饰链，只是 fitted 矩形来源不同：
    /// 适应窗口时内容 = 视口（无滚动，fitted 居中带 16pt 留白）；
    /// 缩放时画布尺寸 = 图像点尺寸 × 倍率，小于视口时通过 fitted 的 origin 居中。
    /// 两态都包在 `EditorCanvasScrollView`（NSScrollView）里 ——
    /// ⌃滚轮 / 捏合缩放、抓手平移、锚点定位都要程序化摸滚动原点，
    /// SwiftUI 的 ScrollView 给不了（见 EditorCanvasScrollView 的说明）。
    private var canvas: some View {
        GeometryReader { geo in
            let viewport = geo.size
            let layout = canvasLayout(viewport: viewport)
            EditorCanvasScrollView(
                contentSize: layout.content,
                panBox: model.panBox,
                onZoom: { factor, docPoint, clipPoint in
                    handleContinuousZoom(
                        factor: factor, docPoint: docPoint,
                        clipPoint: clipPoint, viewport: viewport
                    )
                }
            ) {
                canvasBody(fitted: layout.fitted)
                    .frame(
                        width: layout.content.width,
                        height: layout.content.height,
                        alignment: .topLeading
                    )
            }
        }
    }

    /// 两态统一的画布布局。返回的 `fitted` 同构（origin = 画布在滚动内容里的
    /// 位置），`imagePoint` / 手势因此不区分分支。
    private func canvasLayout(viewport: CGSize) -> (fitted: CGRect, content: CGSize) {
        if let zoom = model.zoomLevel {
            return zoomedRects(zoom: zoom, viewport: viewport)
        }
        // 适应窗口：图片按「视口 - 32pt 留白」适配（尺寸与旧版一致），
        // 但滚动内容是 3× 视口、图片居中 —— 四周各有一个视口的平移余量，
        // 中键 / 滚轮在适应态也能自由挪（无限画布感）。
        // 进入该态时 `panBox.centerOnNextUpdate` 把视口滚到内容中心，
        // 图片落在视口正中，观感与旧版相同。
        let content = CGSize(width: viewport.width * 3, height: viewport.height * 3)
        let inner = CGSize(
            width: max(1, viewport.width - 32),
            height: max(1, viewport.height - 32)
        )
        let fitted = fittedRect(in: inner).offsetBy(
            dx: (content.width - inner.width) / 2,
            dy: (content.height - inner.height) / 2
        )
        return (fitted, content)
    }

    /// 抓手是否生效：常驻抓手或按住空格，且处于缩放态。
    /// 适应态也能平移（中键 / 滚轮，内容 3× 视口），但抓手手势仍限缩放态 ——
    /// 适应态下左键拖拽是「画标注 / 选字」的主通道，空格临时抓手的优先级低。
    private var handModeActive: Bool {
        model.zoomLevel != nil && (model.canvasMode == .hand || spaceMonitor.spaceHeld)
    }

    /// 画布本体 + 手势。`fitted` 是画布在其父容器坐标里的摆放矩形 ——
    /// 视图以 topLeading 参与布局（origin 在父容器 (0,0)），再 offset 到 fitted 的
    /// origin。offset 只挪渲染和命中位置、不动布局 frame，所以手势的 .local 坐标
    /// 落在父容器空间里，`imagePoint` 统一减掉 fitted.origin 再除显示倍率。
    private func canvasBody(fitted: CGRect) -> some View {
        let handActive = handModeActive
        return LayerCanvas(
            shotID: shot.id,
            image: model.canvasImage ?? blankImage,
            layers: annotation.displayLayers.projected(onto: .zero, scale: 1),
            pixelatePreviews: annotation.pixelatePreviews,
            selectedLayerID: annotation.selectedID,
            onCreated: { canvasHolder.view = $0 },
            // 标注图层优先于背景选字：点在自己的图层上时事件归标注，
            // 不交给系统选字层（与下面 DragGesture 的命中口径是同一份）。
            layerHitTest: { annotation.layer(at: $0) != nil }
        )
        .frame(width: fitted.width, height: fitted.height)
        .offset(x: fitted.minX, y: fitted.minY)
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            // 指针模式下悬停到选中图层的缩放控制点 → resize 光标。
            // 坐标映射和下面的 DragGesture 完全一致（同一条修饰链）。
            switch phase {
            case .active(let location):
                canvasHovered = true
                if handModeActive {
                    (panLastWindowLocation == nil
                        ? NSCursor.openHand : NSCursor.closedHand).set()
                    return
                }
                // 文字上显示 I-beam（文本光标准备态）。
                // 钉图是纯 AppKit，系统选字层自己会换 I-beam；编辑器里事件
                // 走窗口级路由，mouseMoved 不经过系统层，得自己设。
                if canvasHolder.view?.hasLiveTextInteractiveItem(
                    atViewLocal: canvasLocalPoint(location, fitted: fitted)
                ) == true {
                    NSCursor.iBeam.set()
                    return
                }
                // 值变了才赋值：strokeScale 挂了 willSet 发布，光标每移一像素都写一次
                // 会让整棵编辑器视图树每帧重建（hover 风暴），拉长选字分析的竞态窗口。
                let hoverScale = Double(CGFloat(max(1, shot.pixelWidth)) / max(1, fitted.width))
                if annotation.strokeScale != hoverScale { annotation.strokeScale = hoverScale }
                if annotation.tool == nil,
                   let handle = annotation.resizeHandle(
                       at: imagePoint(location, fitted: fitted)
                   ) {
                    handle.cursor.set()
                } else {
                    NSCursor.arrow.set()
                }
            case .ended:
                canvasHovered = false
                NSCursor.arrow.set()
            }
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    handleDragChanged(value, fitted: fitted)
                }
                .onEnded { _ in
                    handleDragEnded()
                }
        )
        // 抓手激活时外层平移手势独占（.gesture 掩码屏蔽内层标注手势），
        // 掩码切换不改视图 identity，空格按住 / 松开的瞬间切换不重建画布。
        .gesture(panGesture, including: handActive ? .gesture : .subviews)
    }

    /// 抓手平移：拖多少滚多少（内容跟着光标走）。用窗口坐标算增量 ——
    /// 平移时文档在光标下滑动，本地 / 内容坐标会跟着变，会形成反馈回环。
    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                if let last = panLastWindowLocation {
                    model.panBox.scrollBy(
                        dx: last.x - value.location.x,
                        dy: last.y - value.location.y
                    )
                }
                panLastWindowLocation = value.location
                NSCursor.closedHand.set()
            }
            .onEnded { _ in
                panLastWindowLocation = nil
                NSCursor.openHand.set()
            }
    }

    private func handleDragChanged(_ value: DragGesture.Value, fitted: CGRect) {
        let point = imagePoint(value.location, fitted: fitted)

        if canvasDrag == nil {
            let start = imagePoint(value.startLocation, fitted: fitted)
            // 选字层优先：落点在可拖选的文字上时系统层接管，本手势闲置 ——
            // 否则「拖一次既选了字又画了一笔」（SwiftUI 手势不走 hitTest，
            // 不能指望它自动让位）。
            if canvasHolder.view?.hasLiveTextInteractiveItem(
                atViewLocal: canvasLocalPoint(value.startLocation, fitted: fitted)
            ) == true {
                canvasDrag = .idle
                return
            }
            // 笔宽按显示倍率反算：不论画布被缩到多小，画出来的线在屏幕上都一样粗。
            // 同样只在值变化时赋值（见 onContinuousHover 处的注释）。
            let dragScale = Double(CGFloat(max(1, shot.pixelWidth)) / max(1, fitted.width))
            if annotation.strokeScale != dragScale { annotation.strokeScale = dragScale }

            if annotation.tool == .text {
                placeTextLayer(at: start)
                canvasDrag = .idle
            } else if annotation.tool != nil {
                annotation.beginDraw(at: start)
                canvasDrag = .draw
            } else if let handle = annotation.resizeHandle(at: start) {
                // 选中图层的缩放控制点优先于图层本体的命中。
                annotation.endTextEditing()
                annotation.beginResize(handle: handle, at: start)
                canvasDrag = .resize
            } else if let id = annotation.layer(at: start) {
                annotation.endTextEditing()
                annotation.beginMove(id: id, at: start)
                canvasDrag = .move
            } else {
                annotation.select(nil)
                canvasDrag = .idle
            }
        }

        switch canvasDrag {
        case .draw: annotation.updateDraw(to: point)
        case .move: annotation.updateMove(to: point)
        case .resize: annotation.updateResize(to: point)
        default: break
        }    }

    private func handleDragEnded() {
        switch canvasDrag {
        case .draw:
            annotation.endDraw(pixelSource: model.cropPixels)
            model.refreshCanvasImage()
        case .move:
            annotation.endMove(pixelSource: model.cropPixels)
            model.refreshCanvasImage()
        case .resize:
            annotation.endResize(pixelSource: model.cropPixels)
            model.refreshCanvasImage()
        default:
            break
        }
        canvasDrag = nil    }

    /// 文字工具：落点即建层，给一段占位文字，随即选中并把焦点交给右侧文本框。
    private func placeTextLayer(at point: CGPoint) {
        annotation.beginDraw(at: point)
        guard let id = annotation.editingTextID else { return }
        annotation.insertText("文字")
        annotation.endTextEditing()
        annotation.select(id)
        textFieldFocused = true
    }

    /// 底图还没加载完时的占位，避免把画布做成可选类型污染整个视图树。
    private var blankImage: CGImage {
        CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!.makeImage()!
    }

    private func fittedRect(in size: CGSize) -> CGRect {
        let iw = CGFloat(max(1, shot.pixelWidth))
        let ih = CGFloat(max(1, shot.pixelHeight))
        let scale = min(size.width / iw, size.height / ih)
        let w = iw * scale
        let h = ih * scale
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }

    /// 固定倍率下的布局：画布尺寸 = 图像点尺寸（像素 ÷ shot.scale）× 倍率，
    /// 四周留 16pt 空白；ScrollView 内容至少撑满视口，画布小于视口时居中。
    /// 返回的 `fitted` 与自适应分支同构（origin = 画布在滚动内容里的位置），
    /// `imagePoint` / 手势因此不区分分支。
    private func zoomedRects(
        zoom: Double, viewport: CGSize
    ) -> (fitted: CGRect, content: CGSize) {
        let pointScale = CGFloat(max(1, shot.scale))
        let w = CGFloat(max(1, shot.pixelWidth)) / pointScale * CGFloat(zoom)
        let h = CGFloat(max(1, shot.pixelHeight)) / pointScale * CGFloat(zoom)
        let cw = max(w + 32, viewport.width)
        let ch = max(h + 32, viewport.height)
        return (
            fitted: CGRect(x: (cw - w) / 2, y: (ch - h) / 2, width: w, height: h),
            content: CGSize(width: cw, height: ch)
        )
    }

    /// 视图坐标 → 图像像素坐标（左上原点）。
    private func imagePoint(_ point: CGPoint, fitted: CGRect) -> CGPoint {
        let scale = CGFloat(max(1, shot.pixelWidth)) / max(1, fitted.width)
        return CGPoint(
            x: (point.x - fitted.minX) * scale,
            y: (point.y - fitted.minY) * scale
        )
    }

    /// 修饰链 .local 坐标 → CanvasView 本地坐标。画布被 offset 到 fitted.origin，
    /// offset 只挪命中位置不动布局 frame，所以减掉 origin 即得视图内坐标。
    private func canvasLocalPoint(_ point: CGPoint, fitted: CGRect) -> CGPoint {
        CGPoint(x: point.x - fitted.minX, y: point.y - fitted.minY)
    }

    // MARK: - 缩放控制

    /// 图像的点尺寸（像素 ÷ 显示倍率），model.zoomLevel 的换算基准。
    private var imagePointWidth: CGFloat {
        CGFloat(max(1, shot.pixelWidth)) / CGFloat(max(1, shot.scale))
    }

    /// 当前实际倍率：缩放态就是 model.zoomLevel；适应窗口态用 fitted 宽反推 ——
    /// 从适应态开始连续缩放 / 归档时以它为起点，体验上无跳变。
    private func effectiveZoom(viewport: CGSize) -> Double {
        if let zoom = model.zoomLevel { return zoom }
        guard viewport.width > 1 else { return 1 }
        return Double(canvasLayout(viewport: viewport).fitted.width / imagePointWidth)
    }

    /// ⌃滚轮 / 捏合的连续缩放：锚定光标处的图像点不动。
    private func handleContinuousZoom(
        factor: Double, docPoint: CGPoint, clipPoint: CGPoint, viewport: CGSize
    ) {
        guard viewport.width > 1 else { return }
        let oldZoom = effectiveZoom(viewport: viewport)
        let newZoom = min(Self.zoomRange.upperBound,
                          max(Self.zoomRange.lowerBound, oldZoom * factor))
        applyZoom(newZoom, docPoint: docPoint, clipPoint: clipPoint, viewport: viewport)
    }

    /// 设定新倍率并把 `docPoint`（旧内容坐标系）锚在视口 `clipPoint` 处：
    /// 旧 fitted 反解出图像像素 → 新 fitted 下的内容坐标 → 期望滚动原点，
    /// 写进 pendingOrigin 由滚动容器在内容尺寸更新后的 update 应用（自动钳制）。
    /// 全程只走 fittedRect/imagePoint 那一条公式，坐标不变量不破。
    private func applyZoom(
        _ newZoom: Double, docPoint: CGPoint, clipPoint: CGPoint, viewport: CGSize
    ) {
        let oldFitted = canvasLayout(viewport: viewport).fitted
        let pixel = imagePoint(docPoint, fitted: oldFitted)
        model.zoomLevel = newZoom
        let newFitted = zoomedRects(zoom: newZoom, viewport: viewport).fitted
        let scale = newFitted.width / CGFloat(max(1, shot.pixelWidth))
        model.panBox.pendingOrigin = CGPoint(
            x: newFitted.minX + pixel.x * scale - clipPoint.x,
            y: newFitted.minY + pixel.y * scale - clipPoint.y
        )
    }

    /// 档位直设（缩放菜单 / ⌘± 归档共用）：视口中心为锚。
    private func setZoom(_ zoom: Double) {
        let viewport = model.panBox.viewportSize
        guard viewport.width > 1 else {
            model.zoomLevel = zoom
            return
        }
        let clipPoint = CGPoint(x: viewport.width / 2, y: viewport.height / 2)
        let origin = model.panBox.scrollOrigin
        applyZoom(
            zoom,
            docPoint: CGPoint(x: origin.x + clipPoint.x, y: origin.y + clipPoint.y),
            clipPoint: clipPoint,
            viewport: viewport
        )
    }

    /// 升到下一档。基准是当前**实际**倍率（连续缩放后的散值就近归档，
    /// 适应窗口态用 fitted 反推的倍率），与连续缩放自然共存。
    private func zoomIn() {
        let current = effectiveZoom(viewport: model.panBox.viewportSize)
        setZoom(Self.zoomSteps.first { $0 > current + 0.001 } ?? Self.zoomSteps.last!)
    }

    private func zoomOut() {
        let current = effectiveZoom(viewport: model.panBox.viewportSize)
        setZoom(Self.zoomSteps.last { $0 < current - 0.001 } ?? Self.zoomSteps.first!)
    }

    private var zoomLabel: String {
        model.zoomLevel.map { "\(Int(($0 * 100).rounded()))%" } ?? "适应"
    }

    // MARK: - 右侧面板（已抽至 EditorInspector.swift）

    private var inspector: some View {
        EditorInspector(annotation: annotation, model: model, textFieldFocused: $textFieldFocused)
    }

    // MARK: - 底部状态栏

    private var bottomBar: some View {
        HStack(spacing: DS.s3 - 2) {
            zoomControls

            Divider().frame(height: 14)

            // 尺寸读数：像素尺寸 @ 显示倍率。原图字节从不被修改（见文件头注释）。
            Text("\(shot.pixelWidth) × \(shot.pixelHeight) @\(scaleReadout)x")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            Text(shot.sourceSummary)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)

            Spacer()
            saveStatus
            Button("复制") { copyRendered() }
            Button("导出 PNG") { exportRendered() }
            Button("返回图库") { requestReturnToGallery() }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, DS.s4 - 2)
        .padding(.vertical, DS.s3 - 2)
    }

    /// 缩放控制：`-` / 百分比菜单 / `+`。⌘- 缩小、⌘=（和 ⌘+，见 hiddenShortcuts）
    /// 放大、⌘0 适应窗口。
    private var zoomControls: some View {
        HStack(spacing: DS.s1 / 2) {
            Button {
                zoomOut()
            } label: {
                Image(systemName: "minus.magnifyingglass").frame(width: 22, height: 18)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("-", modifiers: .command)
            .help("缩小（⌘-）")

            Menu {
                ForEach(Self.zoomSteps, id: \.self) { step in
                    Button {
                        setZoom(step)
                    } label: {
                        if model.zoomLevel == step {
                            Label("\(Int((step * 100).rounded()))%", systemImage: "checkmark")
                        } else {
                            Text("\(Int((step * 100).rounded()))%")
                        }
                    }
                }
                Divider()
                Button {
                    model.zoomLevel = nil
                } label: {
                    if model.zoomLevel == nil {
                        Label("适应窗口", systemImage: "checkmark")
                    } else {
                        Text("适应窗口")
                    }
                }
            } label: {
                Text(zoomLabel)
                    .font(.caption.monospacedDigit())
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("缩放（⌘0 适应窗口）")

            Button {
                zoomIn()
            } label: {
                Image(systemName: "plus.magnifyingglass").frame(width: 22, height: 18)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("=", modifiers: .command)
            .help("放大（⌘+）")
        }
    }

    /// 显示倍率读数：整数倍去掉小数点（"2" 而不是 "2.0"）。
    private var scaleReadout: String {
        String(format: "%g", max(1, shot.scale))
    }

    private func rendered() -> CGImage? {
        guard let base = model.baseImage else { return nil }
        return LayerRenderer.render(base: base, layers: model.exportedLayers)
    }

    /// 底栏的保存状态。取代原来那个「保存为新版本」按钮 ——
    /// 自动保存之下按钮没有对象可按，但**人需要知道自己的东西已经安全了**，
    /// 那份安心感原本是靠离开时那个对话框提供的（用一次打断换一次确认）。
    @ViewBuilder
    private var saveStatus: some View {
        // model 是 @StateObject，图层一变本行就跟着重算（未落库 → 「保存中…」）。
        let pending = model.hasPendingChanges

        Label(
            pending ? "保存中…" : (model.savedAt == nil ? "已是最新" : "已保存"),
            systemImage: pending ? "arrow.triangle.2.circlepath" : "checkmark.circle"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .help(pending ? "停手约一秒后自动存为新版本" : "改动已存进修订链，原图从未被修改")
        .accessibilityLabel(pending ? "正在保存" : "已保存")
    }

    // 自动保存（节流、立即冲、内容比对）整段搬进了 `EditorModel` ——
    // 它是数据生命周期，不是视图。

    /// 左上「‹ 图库」/ 底部「返回图库」/ Esc：落库后整窗切回图库模式。
    private func requestReturnToGallery() {
        model.requestReturnToGallery()
    }

    // 这里曾经还有两个对话框，都随自动保存一起删掉了：
    //
    //   · 「有未保存的标注，仍要离开吗？」—— 现在没有「未保存」这个状态了。
    //
    //   · 「图库中已有更新的修订，仍要保存吗？」—— 它防的是「编辑期间别处
    //     （钉图 / 自动脱敏）又落了一版」。但修订链是 append-only 的，追加
    //     从不覆盖任何东西，那个对话框自己的说明里就写着「历史版本都还在，
    //     不会丢失」—— 既然不会丢东西，它就只是在打断人。自动保存之下它更会
    //     在打字打到一半时弹出来。真要更聪明的处理（把两边的图层合并而不是
    //     各存一版），那是另一件事，不该用一个对话框顶着。

    private func copyRendered() {
        guard let image = rendered() else { return }
        Clipboard.copy(image)
    }

    private func exportRendered() {
        guard let image = rendered() else { return }
        _ = try? ImageExporter.exportWithPanel(
            image,
            suggestedName: ImageExporter.suggestedName(for: shot)
        )
    }
}
