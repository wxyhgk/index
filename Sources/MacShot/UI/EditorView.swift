import SwiftUI
import AppKit

/// 非破坏性标注编辑器。
/// 画布上的一切都是图层；保存时只是往 revision 表追加一条记录，原图字节永远不变。
struct EditorView: View {

    let shot: Shot

    @Environment(\.dismiss) private var dismiss
    // 不订阅 store：后台 OCR 回填会触发它发布变更，没必要为此重建整个编辑器。
    private let store = ShotStore.shared

    @State private var baseImage: CGImage?
    /// 底图 + 已应用的马赛克。拖拽过程中不重算，只在图层提交后刷新。
    @State private var canvasImage: CGImage?

    @State private var layers: [Layer] = []
    @State private var selectedLayerID: UUID?
    @State private var tool: Layer.Kind = .rect
    @State private var color: Color = Color(red: 0.98, green: 0.22, blue: 0.22)
    @State private var lineWidth: Double = 4
    @State private var dragStart: CGPoint?
    @State private var dragCurrent: CGPoint?
    @State private var loadedRevisionIndex: Int?

    /// 拖拽标注时 body 每帧都会重建 —— 修订列表绝不能挂在 body 上做数据库查询。
    @State private var revisions: [Revision] = []

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
        .frame(minWidth: 900, minHeight: 620)
        .onAppear(perform: load)
    }

    // MARK: - 加载

    private func load() {
        guard let base = store.originalImage(for: shot) else { return }
        baseImage = base
        revisions = store.revisions(for: shot)
        layers = revisions.last?.layers ?? []
        loadedRevisionIndex = max(0, revisions.count - 1)
        refreshCanvasImage()
    }

    /// 只有马赛克需要走像素管线，这里单独重算一次。
    private func refreshCanvasImage() {
        guard let base = baseImage else { return }
        let pixelates = layers.filter { $0.kind == .pixelate }
        canvasImage = pixelates.isEmpty
            ? base
            : LayerRenderer.render(base: base, layers: Layers(persisted: pixelates))
    }

    // MARK: - 工具栏

    private var toolbar: some View {
        HStack(spacing: 12) {
            ForEach(Layer.Kind.allCases, id: \.self) { kind in
                Button {
                    tool = kind
                } label: {
                    Image(systemName: kind.symbolName)
                        .frame(width: 26, height: 22)
                }
                .buttonStyle(.plain)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(tool == kind ? Color.accentColor.opacity(0.22) : .clear)
                )
                .foregroundStyle(tool == kind ? Color.accentColor : .primary)
                .help(kind.displayName)
            }

            Divider().frame(height: 18)

            ColorPicker("", selection: $color, supportsOpacity: false)
                .labelsHidden()
                .frame(width: 40)

            HStack(spacing: 6) {
                Image(systemName: "lineweight").foregroundStyle(.secondary)
                Slider(value: $lineWidth, in: 1...20).frame(width: 90)
                Text("\(Int(lineWidth))")
                    .font(.caption.monospacedDigit())
                    .frame(width: 18)
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

    // MARK: - 画布

    private var canvas: some View {
        GeometryReader { geo in
            let fitted = fittedRect(in: geo.size)

            LayerCanvas(
                image: canvasImage ?? blankImage,
                // 已提交的马赛克已经烤进底图了，不要再画一遍；正在拖的那个交给渲染器画灰块。
                layers: Layers(persisted: layers.filter { $0.kind != .pixelate })
                    + Layers(persisted: pendingLayer().map { [$0] } ?? []),
                pixelatePreviews: [:],
                selectedLayerID: selectedLayerID
            )
            .frame(width: fitted.width, height: fitted.height)
            .offset(x: fitted.minX, y: fitted.minY)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        dragStart = imagePoint(value.startLocation, fitted: fitted)
                        dragCurrent = imagePoint(value.location, fitted: fitted)
                    }
                    .onEnded { _ in commitDrag() }
            )
        }
        .padding(16)
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

    private func pendingLayer() -> Layer? {
        guard let a = dragStart, let b = dragCurrent else { return nil }
        return makeLayer(from: a, to: b)
    }

    private func makeLayer(from a: CGPoint, to b: CGPoint) -> Layer {
        let c = NSColor(color).usingColorSpace(.sRGB) ?? .systemRed
        var lcolor = LColor(r: c.redComponent, g: c.greenComponent, b: c.blueComponent, a: 1)
        if tool == .highlight { lcolor.a = 0.4 }

        return Layer(
            kind: tool,
            rect: LRect(from: a, to: b),
            color: lcolor,
            lineWidth: lineWidth,
            text: tool == .text ? "双击右侧编辑文字" : "",
            fontSize: max(16, lineWidth * 7)
        )
    }

    private func commitDrag() {
        defer { dragStart = nil; dragCurrent = nil }
        guard let a = dragStart, let b = dragCurrent else { return }
        guard abs(b.x - a.x) > 2 || abs(b.y - a.y) > 2 else { return }

        let layer = makeLayer(from: a, to: b)
        if tool == .crop {
            layers.removeAll { $0.kind == .crop }   // 同时只保留一个裁剪层
        }
        layers.append(layer)
        selectedLayerID = layer.id
        if tool == .pixelate { refreshCanvasImage() }
    }

    // MARK: - 右侧图层面板

    private var inspector: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("图层（\(layers.count)）")
                .font(.headline)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            Divider()

            List(selection: $selectedLayerID) {
                ForEach(layers) { layer in
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
                            layers.removeAll { $0.id == layer.id }
                            if layer.kind == .pixelate { refreshCanvasImage() }
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

            if let index = layers.firstIndex(where: { $0.id == selectedLayerID }),
               layers[index].kind == .text {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Text("文字内容").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $layers[index].text)
                        .font(.system(size: 12))
                        .frame(height: 60)
                        .border(Color.primary.opacity(0.12))
                }
                .padding(12)
            }

            Divider()
            historyPicker
        }
    }

    private var historyPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("历史版本").font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(revisions.enumerated()), id: \.element.id) { index, rev in
                        Button {
                            layers = rev.layers
                            loadedRevisionIndex = index
                            selectedLayerID = nil
                            refreshCanvasImage()
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
        return LayerRenderer.render(base: base, layers: Layers(persisted: layers))
    }

    private func saveRevision() {
        store.appendRevision(shot: shot, layers: Layers(persisted: layers), note: "编辑 \(layers.count) 层")
        revisions = store.revisions(for: shot)
        loadedRevisionIndex = revisions.count - 1
    }

    private func copyRendered() {
        guard let image = rendered() else { return }
        ImageCodec.copyToPasteboard(image)
    }

    private func exportRendered() {
        guard let image = rendered() else { return }
        _ = try? ImageExporter.exportWithPanel(
            image,
            suggestedName: ImageExporter.suggestedName(for: shot)
        )
    }
}
