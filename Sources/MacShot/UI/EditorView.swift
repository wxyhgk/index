import SwiftUI
import AppKit

/// 非破坏性标注编辑器。
/// 画布上的一切都是图层；保存时只是往 revision 表追加一条记录，原图字节永远不变。
///
/// 活在**图库窗口内**（Snagit 的 Editor/Library 单窗口双模式）：
/// `GallerySelection.editingShot` 非 nil 时 GalleryView 整窗切到本视图，
/// 返回图库 = 置回 nil；换图 = 换成目标 shot（宿主用 `.id(shot.id)` 保证重建，
/// `shot` 因此得以保持 `let`，重新走一遍 onAppear → load）。
///
/// 状态机是和截图覆盖层 / 钉图窗口**同一个** `AnnotationState` ——
/// 工具、固定 4 色 3 档粗细、选中 / 拖动 / 删除、全量撤销重做因此完全一致。
/// 编辑器的画布空间就是图片像素（和钉图一样），`CanvasSpace ↔ ImageSpace` 是恒等变换。
struct EditorView: View {

    let shot: Shot

    // 不订阅 store：后台 OCR 回填会触发它发布变更，没必要为此重建整个编辑器。
    private let store = ShotStore.shared

    /// `AnnotationState` 不是 ObservableObject；它的每次变更都经由本视图的
    /// 处理函数发生，处理函数末尾自增这个计数器驱动 SwiftUI 重绘。
    @State private var annotation = AnnotationState()
    @State private var annotationTick = 0

    @State private var baseImage: CGImage?
    /// 底图 + 已应用的马赛克。拖拽过程中不重算，只在图层提交后刷新。
    @State private var canvasImage: CGImage?

    @State private var loadedRevisionIndex: Int?

    /// 未保存检测的基线：最近一次载入 / 保存时的图层数组。
    /// 当前图层与它不等 = 有未保存的标注（换图守卫用，Layer 是 Equatable）。
    @State private var baselineLayers: [Layer] = []

    /// 拖拽标注时 body 每帧都会重建 —— 修订列表绝不能挂在 body 上做数据库查询。
    @State private var revisions: [Revision] = []

    /// 一次画布拖拽在做什么。`idle` 表示这次按下不产生后续（点空处取消选中等）。
    private enum CanvasDrag { case draw, move, resize, idle }
    @State private var canvasDrag: CanvasDrag?

    /// 画布缩放倍率。`nil` = 适应窗口（自适应 fitted 分支）；
    /// 非 nil 时画布尺寸 = 图像点尺寸 × 倍率，包进 ScrollView 可平移。
    @State private var zoomLevel: Double?

    /// 缩放菜单的固定档位。
    private static let zoomSteps: [Double] = [0.25, 0.5, 1, 2, 4]

    /// 右侧面板的两个 tab：图层（列表 + 文字编辑 + 历史版本）/ 效果（美化、水印、外壳）。
    private enum InspectorTab: String, CaseIterable { case layers = "图层", effects = "效果" }
    @State private var inspectorTab: InspectorTab = .layers

    /// 右侧文字框获得焦点时，裸键工具快捷键（R / A / …）必须让位给打字。
    @FocusState private var textFieldFocused: Bool

    /// 编辑器工具栏的展示顺序。`nil` 是指针模式。
    private static let toolOrder: [AnnotationTool?] =
        [nil, .rect, .ellipse, .arrow, .line, .text, .counter, .highlight, .spotlight,
         .dimension, .pixelate, .crop]

    var body: some View {
        // 读一下计数器，让所有标注变更都能触发 body 重算。
        let _ = annotationTick

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
            EditorFilmstrip(currentShotID: shot.id, onSelect: requestSwitch)
        }
        .frame(minWidth: 900, minHeight: 620)
        .background(hiddenShortcuts)
        .onAppear(perform: load)
    }

    // MARK: - 加载

    private func load() {
        guard let base = store.originalImage(for: shot) else { return }
        baseImage = base
        // 编辑器画布就是图像像素；水印字号按图宽 3% 烤入时直接取原图宽。
        annotation.imagePixelWidthProvider = { Double(base.width) }
        // 套壳（frame）的倍率与元数据：编辑器画布就是图像像素，壳的尺寸按 shot.scale
        // 缩放；标题/网址来自采集时的真实归因 —— 竞品的壳是空的，这里是真的。
        annotation.frameScale = max(1, shot.scale)
        annotation.frameDefaultTitle = shot.windowTitle
        annotation.frameDefaultURL = shot.sourceURL
        revisions = store.revisions(for: shot)
        loadRevision(layers: revisions.last?.layers ?? [], index: max(0, revisions.count - 1))
    }

    private func loadRevision(layers: [Layer], index: Int) {
        annotation.load(Layers(persisted: layers), pixelSource: cropPixels)
        baselineLayers = layers
        loadedRevisionIndex = index
        refreshCanvasImage()
        annotationTick += 1
    }

    /// 马赛克贴片的像素来源：编辑器画布就是图片像素，直接从原图裁。
    private func cropPixels(_ rect: CGRect) -> CGImage? {
        baseImage?.cropping(to: rect.integral)
    }

    /// 只有马赛克需要走像素管线，这里单独重算一次。
    private func refreshCanvasImage() {
        guard let base = baseImage else { return }
        let pixelates = exportedLayers.filter { $0.kind == .pixelate }
        canvasImage = pixelates.isEmpty
            ? base
            : LayerRenderer.render(base: base, layers: pixelates)
    }

    /// 恒等投影到图像像素空间 —— 入库、导出、烤底图都用这一份。
    private var exportedLayers: Layers<ImageSpace> {
        annotation.layers.projected(onto: .zero, scale: 1)
    }

    // MARK: - 工具栏

    private var toolbar: some View {
        HStack(spacing: 12) {
            // Snagit 的 Editor/Library 位：左上角返回图库（同一窗口整体切回）。
            Button {
                requestReturnToGallery()
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                    Text("图库")
                }
                .frame(height: 44)
                .padding(.horizontal, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("返回图库（⎋）")

            Divider().frame(height: 24)

            // Snagit 式大按钮：图标上、标签下，工具一目了然。
            HStack(spacing: 2) {
                ForEach(Array(Self.toolOrder.enumerated()), id: \.offset) { _, tool in
                    toolButton(tool)
                }
            }

            Spacer(minLength: DS.s2)

            // 颜色 / 粗细保持小控件，靠右紧凑放。
            HStack(spacing: 4) {
                ForEach(AnnotationState.palette.indices, id: \.self) { index in
                    colorButton(index)
                }
            }

            Divider().frame(height: 18)

            HStack(spacing: 4) {
                ForEach(AnnotationState.widths.indices, id: \.self) { index in
                    widthButton(index)
                }
            }

            Divider().frame(height: 18)

            Button {
                performUndo()
            } label: {
                Image(systemName: "arrow.uturn.backward").frame(width: 26, height: 22)
            }
            .buttonStyle(.plain)
            .disabled(!annotation.canUndo)
            .keyboardShortcut("z", modifiers: .command)
            .help("撤销（⌘Z）")

            Button {
                performRedo()
            } label: {
                Image(systemName: "arrow.uturn.forward").frame(width: 26, height: 22)
            }
            .buttonStyle(.plain)
            .disabled(!annotation.canRedo)
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .help("重做（⇧⌘Z）")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    private func toolButton(_ tool: AnnotationTool?) -> some View {
        let selected = annotation.tool == tool
        let shortcut = AnnotationTool.shortcuts.first { $0.tool == tool }

        return Button {
            selectTool(tool)
        } label: {
            VStack(spacing: 3) {
                Image(systemName: tool?.symbolName ?? "cursorarrow")
                    .font(.system(size: 15))
                    .frame(height: 18)
                Text(tool?.title ?? "指针")
                    .font(.caption2)
            }
            .frame(width: 48, height: 44)
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: DS.radiusSmall)
                .fill(selected ? Color.accentColor.opacity(0.22) : .clear)
        )
        .foregroundStyle(selected ? Color.accentColor : .primary)
        .keyboardShortcut(bareKeyShortcut(shortcut?.label))
        .help(shortcut.map { "\($0.toolName)（\($0.label)）" } ?? tool?.title ?? "指针")
    }

    /// 裸键快捷键（无修饰）。文字框在打字时返回 nil，把按键让给输入。
    /// 显式限定 `SwiftUI.`：项目里有个同名的全局热键类型（Settings/KeyboardShortcut.swift）。
    private func bareKeyShortcut(_ label: String?) -> SwiftUI.KeyboardShortcut? {
        guard !textFieldFocused,
              let ch = label?.lowercased().first else { return nil }
        return SwiftUI.KeyboardShortcut(KeyEquivalent(ch), modifiers: [])
    }

    private func colorButton(_ index: Int) -> some View {
        let c = AnnotationState.palette[index]
        let selected = annotation.colorIndex == index
        return Button {
            annotation.colorIndex = index
            annotation.applyColorToSelection()
            annotationTick += 1
        } label: {
            Circle()
                .fill(Color(.sRGB, red: c.r, green: c.g, blue: c.b))
                .overlay(Circle().strokeBorder(.black.opacity(0.25)))
                .frame(width: 14, height: 14)
                .padding(3)
                .overlay(
                    Circle().strokeBorder(
                        selected ? Color.accentColor : .clear,
                        lineWidth: 1.5
                    )
                )
        }
        .buttonStyle(.plain)
        .help("颜色 \(index + 1)")
    }

    private func widthButton(_ index: Int) -> some View {
        let diameter = CGFloat(AnnotationState.widths[index]) + 3
        let selected = annotation.widthIndex == index
        return Button {
            annotation.widthIndex = index
            annotation.applyWidthToSelection()
            annotationTick += 1
        } label: {
            Circle()
                .fill(selected ? Color.accentColor : Color.primary.opacity(0.75))
                .frame(width: diameter, height: diameter)
                .frame(width: 20, height: 20)
        }
        .buttonStyle(.plain)
        .help("粗细 \(index + 1)")
    }

    // MARK: - 效果面板（右侧「效果」tab）

    /// 效果 tab：每个效果一行分组卡片（开关 + 展开的样式子选项）。
    /// 行样式对齐图库 inspector：quaternary 底 + DS.radiusCard + caption.semibold 组题。
    private var effectsPanel: some View {
        ScrollView {
            VStack(spacing: DS.s3) {
                backdropCard
                watermarkCard
                frameCard
                EditorCaptureInfoRow(annotation: annotation, shot: shot) {
                    annotationTick += 1
                }
            }
            .padding(DS.s3)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// 分组卡片骨架：组题 + 右侧开关，开着时展开子选项。
    private func effectCard(
        _ title: String,
        isOn: Bool,
        toggle: @escaping () -> Void,
        @ViewBuilder options: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: DS.s2) {
            HStack {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Toggle(title, isOn: Binding(get: { isOn }, set: { _ in toggle() }))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
            }
            if isOn {
                options()
            }
        }
        .padding(DS.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: DS.radiusCard))
    }

    /// 美化行。backdrop 只影响导出/复制/保存的成品 ——
    /// 画布预览刻意不变（见 `AnnotationRenderer` 的说明），开关表达状态。
    /// 预设色块点选即换（`setBackdropPreset`），作为一条可撤销的 style 记录。
    private var backdropCard: some View {
        effectCard("美化", isOn: annotation.hasBackdrop, toggle: {
            annotation.toggleBackdrop()
            annotationTick += 1
        }) {
            HStack(spacing: DS.s2) {
                ForEach(BackdropPreset.allCases, id: \.rawValue) { preset in
                    backdropSwatch(preset)
                }
            }
        }
    }

    /// 背景预设小色块：渐变预设画渐变、纯色预设画灰块，选中态描 accent 边。
    private func backdropSwatch(_ preset: BackdropPreset) -> some View {
        let selected = annotation.backdropPresetID == preset.rawValue
        return Button {
            annotation.setBackdropPreset(preset.rawValue)
            annotationTick += 1
        } label: {
            RoundedRectangle(cornerRadius: DS.radiusSmall)
                .fill(swatchGradient(preset))
                .frame(width: 40, height: 26)
                .overlay(
                    RoundedRectangle(cornerRadius: DS.radiusSmall)
                        .strokeBorder(
                            selected ? Color.accentColor : Color.primary.opacity(0.12),
                            lineWidth: selected ? 2 : 1
                        )
                )
        }
        .buttonStyle(.plain)
        .help(preset.displayName)
    }

    private func swatchGradient(_ preset: BackdropPreset) -> LinearGradient {
        guard let (a, b) = preset.gradientColors else {
            // solid 预设：导出时用图层自身颜色，色块示意为中性灰。
            return LinearGradient(
                colors: [Color(.sRGB, white: 0.4, opacity: 1)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        }
        return LinearGradient(
            colors: [Color(cgColor: a), Color(cgColor: b)],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
    }

    /// 水印行。按设置里的参数造层（没配文案时用 "MacShot" 兜底）。
    /// 和美化不同，水印会画进画布预览 —— 它影响构图判断。
    /// 位置三选走 `setWatermarkMode`，作为一条可撤销的 style 记录。
    private var watermarkCard: some View {
        effectCard("水印", isOn: annotation.hasWatermark, toggle: {
            let settings = AppSettings.shared
            let text = settings.trimmedWatermarkText
            annotation.toggleWatermark(
                text: text.isEmpty ? "MacShot" : text,
                mode: settings.watermarkMode,
                alpha: settings.watermarkAlpha
            )
            annotationTick += 1
        }) {
            Picker("水印位置", selection: Binding(
                get: { annotation.watermarkMode ?? .corner },
                set: { mode in
                    annotation.setWatermarkMode(mode)
                    annotationTick += 1
                }
            )) {
                ForEach(WatermarkMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    /// 外壳行。frame 只影响导出/复制/保存的成品，画布预览刻意不变（同美化的取舍）。
    /// 开壳时把 shot 的真实窗口标题 / 网址烤进壳的参数 JSON（见 `load`）；
    /// 样式二选走 `setFrameStyle`，作为一条可撤销的 style 记录。
    private var frameCard: some View {
        effectCard("外壳", isOn: annotation.hasFrame, toggle: {
            annotation.toggleFrame()
            annotationTick += 1
        }) {
            Picker("壳样式", selection: Binding(
                get: { annotation.frameStyle ?? .macos },
                set: { style in
                    annotation.setFrameStyle(style)
                    annotationTick += 1
                }
            )) {
                ForEach(FrameSpec.Style.allCases, id: \.rawValue) { style in
                    Text(style.displayName).tag(style)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    private func selectTool(_ tool: AnnotationTool?) {
        annotation.endTextEditing()
        annotation.tool = tool
        annotationTick += 1
    }

    /// 不可见按钮承载的快捷键：⌫ 删除选中图层（打字时禁用，退格让给文字框）、
    /// ⌘0 适应窗口、⌘+ 放大（⌘= 挂在底栏的加号按钮上，这里补真正的 "+" 键）。
    private var hiddenShortcuts: some View {
        Group {
            Button("删除选中图层") { performDelete() }
                .keyboardShortcut(.delete, modifiers: [])
                .disabled(textFieldFocused || annotation.selectedID == nil)
            Button("适应窗口") { zoomLevel = nil }
                .keyboardShortcut("0", modifiers: .command)
            Button("放大") { zoomIn() }
                .keyboardShortcut("+", modifiers: .command)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    // MARK: - 操作

    private func performUndo() {
        guard annotation.undo() else { return }
        refreshCanvasImage()
        annotationTick += 1
    }

    private func performRedo() {
        guard annotation.redo() else { return }
        refreshCanvasImage()
        annotationTick += 1
    }

    private func performDelete() {
        guard annotation.deleteSelected() else { return }
        refreshCanvasImage()
        annotationTick += 1
    }

    // MARK: - 画布

    /// 两种布局分支共用一条 `canvasBody` 修饰链，只是 fitted 矩形来源不同：
    /// 适应窗口时由视口大小算 fitted；缩放时画布尺寸 = 图像点尺寸 × 倍率，
    /// 包进双向 ScrollView 平移，小于视口时通过 fitted 的 origin 居中。
    @ViewBuilder
    private var canvas: some View {
        if let zoom = zoomLevel {
            GeometryReader { geo in
                let rects = zoomedRects(zoom: zoom, viewport: geo.size)
                ScrollView([.horizontal, .vertical]) {
                    canvasBody(fitted: rects.fitted)
                        .frame(
                            width: rects.content.width,
                            height: rects.content.height,
                            alignment: .topLeading
                        )
                }
            }
        } else {
            GeometryReader { geo in
                canvasBody(fitted: fittedRect(in: geo.size))
            }
            .padding(16)
        }
    }

    /// 画布本体 + 手势。`fitted` 是画布在其父容器坐标里的摆放矩形 ——
    /// 视图以 topLeading 参与布局（origin 在父容器 (0,0)），再 offset 到 fitted 的
    /// origin。offset 只挪渲染和命中位置、不动布局 frame，所以手势的 .local 坐标
    /// 落在父容器空间里，`imagePoint` 统一减掉 fitted.origin 再除显示倍率。
    private func canvasBody(fitted: CGRect) -> some View {
        LayerCanvas(
            image: canvasImage ?? blankImage,
            layers: annotation.displayLayers.projected(onto: .zero, scale: 1),
            pixelatePreviews: annotation.pixelatePreviews,
            selectedLayerID: annotation.selectedID
        )
        .frame(width: fitted.width, height: fitted.height)
        .offset(x: fitted.minX, y: fitted.minY)
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            // 指针模式下悬停到选中图层的缩放控制点 → resize 光标。
            // 坐标映射和下面的 DragGesture 完全一致（同一条修饰链）。
            switch phase {
            case .active(let location):
                annotation.strokeScale = Double(
                    CGFloat(max(1, shot.pixelWidth)) / max(1, fitted.width)
                )
                if annotation.tool == nil,
                   let handle = annotation.resizeHandle(
                       at: imagePoint(location, fitted: fitted)
                   ) {
                    handle.cursor.set()
                } else {
                    NSCursor.arrow.set()
                }
            case .ended:
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
    }

    private func handleDragChanged(_ value: DragGesture.Value, fitted: CGRect) {
        let point = imagePoint(value.location, fitted: fitted)

        if canvasDrag == nil {
            let start = imagePoint(value.startLocation, fitted: fitted)
            // 笔宽按显示倍率反算：不论画布被缩到多小，画出来的线在屏幕上都一样粗。
            annotation.strokeScale = Double(
                CGFloat(max(1, shot.pixelWidth)) / max(1, fitted.width)
            )

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
        }
        annotationTick += 1
    }

    private func handleDragEnded() {
        switch canvasDrag {
        case .draw:
            annotation.endDraw(pixelSource: cropPixels)
            refreshCanvasImage()
        case .move:
            annotation.endMove(pixelSource: cropPixels)
            refreshCanvasImage()
        case .resize:
            annotation.endResize(pixelSource: cropPixels)
            refreshCanvasImage()
        default:
            break
        }
        canvasDrag = nil
        annotationTick += 1
    }

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

    // MARK: - 缩放控制

    /// 升到下一档；已是最大档或从「适应窗口」起步时按 100% 为基准。
    private func zoomIn() {
        let current = zoomLevel ?? 1
        zoomLevel = Self.zoomSteps.first { $0 > current + 0.001 } ?? Self.zoomSteps.last
    }

    private func zoomOut() {
        let current = zoomLevel ?? 1
        zoomLevel = Self.zoomSteps.last { $0 < current - 0.001 } ?? Self.zoomSteps.first
    }

    private var zoomLabel: String {
        zoomLevel.map { "\(Int(($0 * 100).rounded()))%" } ?? "适应"
    }

    // MARK: - 右侧面板（图层 / 效果双 tab）

    private var inspector: some View {
        VStack(spacing: 0) {
            Picker("面板", selection: $inspectorTab) {
                ForEach(InspectorTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, DS.s3)
            .padding(.vertical, DS.s2)

            Divider()

            switch inspectorTab {
            case .layers: layersPanel
            case .effects: effectsPanel
            }
        }
    }

    private var layersPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("图层（\(annotation.layers.count)）")
                .font(.headline)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            Divider()

            List(selection: selectionBinding) {
                ForEach(annotation.layers.elements) { layer in
                    HStack(spacing: 8) {
                        Image(systemName: layer.kind.symbolName)
                            .foregroundStyle(Color(
                                .sRGB, red: layer.color.r, green: layer.color.g,
                                blue: layer.color.b, opacity: 1
                            ))
                        Text(layer.kind.displayName)
                            .font(.caption)
                        Spacer()
                        Button {
                            annotation.select(layer.id)
                            performDelete()
                        } label: {
                            Image(systemName: "trash").font(.caption2)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                    .tag(layer.id)
                }
            }
            .listStyle(.inset)

            if let selectedID = annotation.selectedID,
               let index = annotation.layers.firstIndex(id: selectedID),
               annotation.layers[index].kind == .text {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Text("文字内容").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: textBinding(for: selectedID))
                        .font(.system(size: 12))
                        .frame(height: 60)
                        .border(Color.primary.opacity(0.12))
                        .focused($textFieldFocused)
                }
                .padding(12)
            }

            Divider()
            historyPicker
        }
    }

    private var selectionBinding: Binding<UUID?> {
        Binding(
            get: { annotation.selectedID },
            set: { id in
                annotation.select(id)
                annotationTick += 1
            }
        )
    }

    /// 文字改动走 `setText` 入撤销栈（连续输入合并成一条记录），
    /// 绝不直接改图层数组 —— 那是旧路径，绕开撤销。
    private func textBinding(for id: UUID) -> Binding<String> {
        Binding(
            get: {
                annotation.layers.firstIndex(id: id).map { annotation.layers[$0].text } ?? ""
            },
            set: { text in
                annotation.setText(id: id, text)
                annotationTick += 1
            }
        )
    }

    private var historyPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("历史版本").font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(revisions.enumerated()), id: \.element.id) { index, rev in
                        Button {
                            loadRevision(layers: rev.layers, index: index)
                        } label: {
                            HStack {
                                Text("v\(index + 1)")
                                    .font(.caption.monospacedDigit())
                                Text(rev.note ?? "编辑")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text("\(rev.layers.count) 层")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 3)
                            .padding(.horizontal, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(loadedRevisionIndex == index
                                          ? Color.accentColor.opacity(0.18) : .clear)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: 120)
        }
        .padding(12)
    }

    // MARK: - 底部状态栏

    private var bottomBar: some View {
        HStack(spacing: 10) {
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
            Button("复制") { copyRendered() }
            Button("导出 PNG") { exportRendered() }
            Button("保存为新版本") { saveRevision() }
                .keyboardShortcut("s", modifiers: .command)
                .buttonStyle(.borderedProminent)
            Button("返回图库") { requestReturnToGallery() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// 缩放控制：`-` / 百分比菜单 / `+`。⌘- 缩小、⌘=（和 ⌘+，见 hiddenShortcuts）
    /// 放大、⌘0 适应窗口。
    private var zoomControls: some View {
        HStack(spacing: 2) {
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
                        zoomLevel = step
                    } label: {
                        if zoomLevel == step {
                            Label("\(Int((step * 100).rounded()))%", systemImage: "checkmark")
                        } else {
                            Text("\(Int((step * 100).rounded()))%")
                        }
                    }
                }
                Divider()
                Button {
                    zoomLevel = nil
                } label: {
                    if zoomLevel == nil {
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
        guard let base = baseImage else { return nil }
        return LayerRenderer.render(base: base, layers: exportedLayers)
    }

    private func saveRevision() {
        annotation.endTextEditing()
        guard confirmSaveOverNewerRevision() else { return }
        store.appendRevision(
            shot: shot,
            layers: exportedLayers,
            note: "编辑 \(annotation.layers.count) 层"
        )
        revisions = store.revisions(for: shot)
        loadedRevisionIndex = revisions.count - 1
        baselineLayers = exportedLayers.persisted
        annotationTick += 1
    }

    /// 胶片条点击换图。未保存守卫通过后直接换 `editingShot` ——
    /// 宿主（GalleryView）挂了 `.id(shot.id)`，identity 变化即重建本视图完成切换。
    private func requestSwitch(to target: Shot) {
        guard target.id != shot.id, resolveUnsavedChanges() else { return }
        GallerySelection.shared.editingShot = target
    }

    /// 左上「‹ 图库」/ 底部「返回图库」/ Esc：守卫通过后整窗切回图库模式。
    private func requestReturnToGallery() {
        guard resolveUnsavedChanges() else { return }
        GallerySelection.shared.editingShot = nil
    }

    /// 未保存守卫（返回图库和换图共用）。有未保存的标注时先问一声
    /// （保存并继续 / 不保存继续 / 取消）；返回 true = 可以离开当前画布。
    private func resolveUnsavedChanges() -> Bool {
        annotation.endTextEditing()
        guard exportedLayers.persisted != baselineLayers else { return true }

        let alert = NSAlert()
        alert.messageText = "有未保存的标注，仍要离开吗？"
        alert.informativeText = "当前画布上的改动还没有保存为新版本，离开后会丢失。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "保存并继续")
        alert.addButton(withTitle: "不保存继续")
        alert.addButton(withTitle: "取消")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            saveRevision()
            // 保存可能被并发修订确认（confirmSaveOverNewerRevision）取消 ——
            // 那样基线不会更新，改动仍未保存，不能走。
            return exportedLayers.persisted == baselineLayers
        case .alertSecondButtonReturn:
            return true
        default:
            return false
        }
    }

    /// 并发保存检测：修订链本身由 appendRevision 的单事务保证线性
    /// （不会坏链），但后保存的一方是基于打开时的旧图层覆盖式追加 ——
    /// 图库里已经出现更新的修订（钉图 / 自动脱敏落的）时，
    /// 先问一声再追加。`revisions` 在打开和每次保存后都会与库同步，
    /// 它的尾项就是本编辑器所认知的「最新」。
    private func confirmSaveOverNewerRevision() -> Bool {
        guard store.latestRevision(for: shot)?.id != revisions.last?.id else { return true }

        let alert = NSAlert()
        alert.messageText = "图库中已有更新的修订，仍要保存吗？"
        alert.informativeText = "这张截图在别处（钉图或自动脱敏）"
            + "已保存了更新的版本。继续保存会把当前画布内容追加为最新修订，"
            + "历史版本都还在，不会丢失。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "仍要保存")
        alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn
    }

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
