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

    @Environment(\.dismiss) private var dismiss
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

    /// 拖拽标注时 body 每帧都会重建 —— 修订列表绝不能挂在 body 上做数据库查询。
    @State private var revisions: [Revision] = []

    /// 一次画布拖拽在做什么。`idle` 表示这次按下不产生后续（点空处取消选中等）。
    private enum CanvasDrag { case draw, move, idle }
    @State private var canvasDrag: CanvasDrag?

    /// 右侧文字框获得焦点时，裸键工具快捷键（R / A / …）必须让位给打字。
    @FocusState private var textFieldFocused: Bool

    /// 编辑器工具栏的展示顺序。`nil` 是指针模式。
    private static let toolOrder: [AnnotationTool?] =
        [nil, .rect, .ellipse, .arrow, .line, .text, .counter, .highlight, .spotlight, .pixelate, .crop]

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
        }
        .frame(minWidth: 900, minHeight: 620)
        .background(hiddenShortcuts)
        .onAppear(perform: load)
    }

    // MARK: - 加载

    private func load() {
        guard let base = store.originalImage(for: shot) else { return }
        baseImage = base
        revisions = store.revisions(for: shot)
        loadRevision(layers: revisions.last?.layers ?? [], index: max(0, revisions.count - 1))
    }

    private func loadRevision(layers: [Layer], index: Int) {
        annotation.load(Layers(persisted: layers), pixelSource: cropPixels)
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

            backdropToggle

            if annotation.hasBackdrop {
                backdropPresetMenu
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
            Button("关闭") { dismiss() }
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
        store.appendRevision(
            shot: shot,
            layers: exportedLayers,
            note: "编辑 \(annotation.layers.count) 层"
        )
        revisions = store.revisions(for: shot)
        loadedRevisionIndex = revisions.count - 1
        annotationTick += 1
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
