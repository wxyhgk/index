import SwiftUI
import AppKit

/// 非破坏性标注编辑器。
/// 画布上的一切都是图层；保存时只是往 revision 表追加一条记录，原图字节永远不变。
///
/// 状态机是和截图覆盖层 / 钉图窗口**同一个** `AnnotationState` ——
/// 工具、固定 4 色 3 档粗细、选中 / 拖动 / 删除、全量撤销重做因此完全一致。
/// 编辑器的画布空间就是图片像素（和钉图一样），`CanvasSpace ↔ ImageSpace` 是恒等变换。
struct EditorView: View {

    let shot: Shot
    /// 关闭宿主窗口。编辑器活在独立 NSWindow 里（EditorWindowController），
    /// SwiftUI 的 `dismiss` 环境值在这儿不起作用，由窗口控制器注入。
    let onClose: () -> Void
    /// 胶片条换图：由窗口控制器注入，控制器**重建 rootView** 完成切换
    /// （`shot` 因此得以保持 `let`）。未保存守卫在本视图侧（见 `requestSwitch`）。
    let onSwitchShot: (Shot) -> Void

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
            HStack(spacing: 2) {
                ForEach(Array(Self.toolOrder.enumerated()), id: \.offset) { _, tool in
                    toolButton(tool)
                }
            }

            Divider().frame(height: 18)

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

            Divider().frame(height: 18)

            // 三组输出选项包进 Group：HStack 的 ViewBuilder 最多 10 个子视图，
            // 开关 + 条件菜单已经把名额吃满了。
            Group {
                backdropToggle
                if annotation.hasBackdrop {
                    backdropPresetMenu
                }
                watermarkToggle
                if annotation.hasWatermark {
                    watermarkModeMenu
                }
                frameToggle
                if annotation.hasFrame {
                    frameStyleMenu
                }
            }

            Spacer()

            Text(shot.sourceSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private func toolButton(_ tool: AnnotationTool?) -> some View {
        let selected = annotation.tool == tool
        let shortcut = AnnotationTool.shortcuts.first { $0.tool == tool }

        return Button {
            selectTool(tool)
        } label: {
            Image(systemName: tool?.symbolName ?? "cursorarrow")
                .frame(width: 26, height: 22)
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 5)
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

    /// 美化开关。backdrop 只影响导出/复制/保存的成品 ——
    /// 画布预览刻意不变（见 `AnnotationRenderer` 的说明），按钮高亮表达状态。
    private var backdropToggle: some View {
        let on = annotation.hasBackdrop
        return Button {
            annotation.toggleBackdrop()
            annotationTick += 1
        } label: {
            Image(systemName: "sparkles").frame(width: 26, height: 22)
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(on ? Color.accentColor.opacity(0.22) : .clear)
        )
        .foregroundStyle(on ? Color.accentColor : .primary)
        .help("美化背景（导出时垫渐变背景 + 圆角 + 阴影）")
    }

    /// 背景预设选择。选中即替换 backdrop 层的预设名，作为一条可撤销的 style 记录。
    private var backdropPresetMenu: some View {
        Menu {
            ForEach(BackdropPreset.allCases, id: \.rawValue) { preset in
                Button {
                    annotation.setBackdropPreset(preset.rawValue)
                    annotationTick += 1
                } label: {
                    if annotation.backdropPresetID == preset.rawValue {
                        Label(preset.displayName, systemImage: "checkmark")
                    } else {
                        Text(preset.displayName)
                    }
                }
            }
        } label: {
            Image(systemName: "paintpalette").frame(width: 26, height: 22)
        }
        .menuStyle(.borderlessButton)
        .frame(width: 40)
        .help("美化背景预设")
    }

    /// 水印开关。按设置里的参数造层（没配文案时用 "MacShot" 兜底）。
    /// 和美化不同，水印会画进画布预览 —— 它影响构图判断。
    private var watermarkToggle: some View {
        let on = annotation.hasWatermark
        return Button {
            let settings = AppSettings.shared
            let text = settings.trimmedWatermarkText
            annotation.toggleWatermark(
                text: text.isEmpty ? "MacShot" : text,
                mode: settings.watermarkMode,
                alpha: settings.watermarkAlpha
            )
            annotationTick += 1
        } label: {
            Image(systemName: "signature").frame(width: 26, height: 22)
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(on ? Color.accentColor.opacity(0.22) : .clear)
        )
        .foregroundStyle(on ? Color.accentColor : .primary)
        .help("水印（文字盖在成品上，文案/透明度见设置）")
    }

    /// 水印位置切换。选中即替换 watermark 层的模式，作为一条可撤销的 style 记录。
    private var watermarkModeMenu: some View {
        Menu {
            ForEach(WatermarkMode.allCases) { mode in
                Button {
                    annotation.setWatermarkMode(mode)
                    annotationTick += 1
                } label: {
                    if annotation.watermarkMode == mode {
                        Label(mode.displayName, systemImage: "checkmark")
                    } else {
                        Text(mode.displayName)
                    }
                }
            }
        } label: {
            Image(systemName: "square.grid.3x3").frame(width: 26, height: 22)
        }
        .menuStyle(.borderlessButton)
        .frame(width: 40)
        .help("水印位置")
    }

    /// 套壳开关。frame 只影响导出/复制/保存的成品，画布预览刻意不变（同美化的取舍）。
    /// 开壳时把 shot 的真实窗口标题 / 网址烤进壳的参数 JSON（见 `load`）。
    private var frameToggle: some View {
        let on = annotation.hasFrame
        return Button {
            annotation.toggleFrame()
            annotationTick += 1
        } label: {
            Image(systemName: "macwindow").frame(width: 26, height: 22)
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(on ? Color.accentColor.opacity(0.22) : .clear)
        )
        .foregroundStyle(on ? Color.accentColor : .primary)
        .help("带壳截图（导出时套 macOS 窗口 / 浏览器壳，标题和网址是真实元数据）")
    }

    /// 壳样式切换（macOS 窗口 / 浏览器）。选中即改写壳的参数 JSON，
    /// 作为一条可撤销的 style 记录。
    private var frameStyleMenu: some View {
        Menu {
            ForEach(FrameSpec.Style.allCases, id: \.rawValue) { style in
                Button {
                    annotation.setFrameStyle(style)
                    annotationTick += 1
                } label: {
                    if annotation.frameStyle == style {
                        Label(style.displayName, systemImage: "checkmark")
                    } else {
                        Text(style.displayName)
                    }
                }
            }
        } label: {
            Image(systemName: "menubar.dock.rectangle").frame(width: 26, height: 22)
        }
        .menuStyle(.borderlessButton)
        .frame(width: 40)
        .help("壳样式")
    }

    private func selectTool(_ tool: AnnotationTool?) {
        annotation.endTextEditing()
        annotation.tool = tool
        annotationTick += 1
    }

    /// ⌫ 删除选中图层。挂在一个不可见按钮上；打字时禁用，退格让给文字框。
    private var hiddenShortcuts: some View {
        Button("删除选中图层") { performDelete() }
            .keyboardShortcut(.delete, modifiers: [])
            .disabled(textFieldFocused || annotation.selectedID == nil)
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

    private var canvas: some View {
        GeometryReader { geo in
            let fitted = fittedRect(in: geo.size)

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
        .padding(16)
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

    /// 视图坐标 → 图像像素坐标（左上原点）。
    private func imagePoint(_ point: CGPoint, fitted: CGRect) -> CGPoint {
        let scale = CGFloat(max(1, shot.pixelWidth)) / max(1, fitted.width)
        return CGPoint(
            x: (point.x - fitted.minX) * scale,
            y: (point.y - fitted.minY) * scale
        )
    }

    // MARK: - 右侧图层面板

    private var inspector: some View {
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

    // MARK: - 底部

    private var bottomBar: some View {
        HStack(spacing: 10) {
            Text("原图 \(shot.pixelWidth) × \(shot.pixelHeight) · 从不被修改")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("复制") { copyRendered() }
            Button("导出 PNG") { exportRendered() }
            Button("保存为新版本") { saveRevision() }
                .keyboardShortcut("s", modifiers: .command)
                .buttonStyle(.borderedProminent)
            Button("关闭") { onClose() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
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

    /// 胶片条点击换图。有未保存的标注时先问一声（保存并切换 / 不保存切换 / 取消），
    /// 守卫通过才把请求转给窗口控制器（它重建 rootView 完成切换）。
    private func requestSwitch(to target: Shot) {
        guard target.id != shot.id else { return }
        annotation.endTextEditing()
        if exportedLayers.persisted != baselineLayers {
            let alert = NSAlert()
            alert.messageText = "有未保存的标注，仍要切换吗？"
            alert.informativeText = "当前画布上的改动还没有保存为新版本，切换后会丢失。"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "保存并切换")
            alert.addButton(withTitle: "不保存切换")
            alert.addButton(withTitle: "取消")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                saveRevision()
                // 保存可能被并发修订确认（confirmSaveOverNewerRevision）取消 ——
                // 那样基线不会更新，改动仍未保存，不能切。
                guard exportedLayers.persisted == baselineLayers else { return }
            case .alertSecondButtonReturn:
                break
            default:
                return
            }
        }
        onSwitchShot(target)
    }

    /// 多窗口下的并发保存检测：修订链本身由 appendRevision 的单事务保证线性
    /// （不会坏链），但后保存的一方是基于打开时的旧图层覆盖式追加 ——
    /// 图库里已经出现更新的修订（另一个编辑器窗口 / 钉图 / 自动脱敏落的）时，
    /// 先问一声再追加。`revisions` 在打开和每次保存后都会与库同步，
    /// 它的尾项就是本窗口所认知的「最新」。
    private func confirmSaveOverNewerRevision() -> Bool {
        guard store.latestRevision(for: shot)?.id != revisions.last?.id else { return true }

        let alert = NSAlert()
        alert.messageText = "图库中已有更新的修订，仍要保存吗？"
        alert.informativeText = "这张截图在别处（另一个编辑器窗口、钉图或自动脱敏）"
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
