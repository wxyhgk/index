import SwiftUI

enum EditorInspectorOrdering {
    /// 图层数组按绘制顺序保存（越靠后越在上面），面板要反过来展示，
    /// 才符合图像编辑器里“列表顶部 = 画面顶层”的惯例。
    static func visibleLayersTopFirst(_ layers: [Layer]) -> [Layer] {
        Array(layers.filter { !$0.kind.isEffect }.reversed())
    }

    /// 修订仓库按时间正序返回；历史面板把最新版放在最容易看到的顶部。
    static func newestFirstIndices(count: Int) -> [Int] {
        Array((0..<count).reversed())
    }
}

/// 右侧面板。图层、成品效果和修订历史是三种不同任务，不再把历史
/// 压在图层列表最底部；空图层时也给出下一步提示，而不是留一整块黑色空白。
struct EditorInspector: View {

    @ObservedObject var annotation: AnnotationState
    @ObservedObject var model: EditorModel
    var textFieldFocused: FocusState<Bool>.Binding

    private enum Tab: String, CaseIterable {
        case layers = "图层"
        case effects = "效果"
        case history = "历史"
    }
    @State private var tab: Tab = .layers

    var body: some View {
        VStack(spacing: 0) {
            Picker("面板", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { t in Text(t.rawValue).tag(t) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, DS.s3)
            .padding(.vertical, DS.s2)

            Divider()

            switch tab {
            case .layers:
                EditorLayersPanel(annotation: annotation, model: model, textFieldFocused: textFieldFocused)
            case .effects:
                EditorEffectsPanel(model: model)
            case .history:
                EditorHistoryPanel(model: model)
            }
        }
    }
}

/// 图层列表 + 选中文字编辑。
private struct EditorLayersPanel: View {

    @ObservedObject var annotation: AnnotationState
    @ObservedObject var model: EditorModel
    var textFieldFocused: FocusState<Bool>.Binding

    private var listedLayers: [Layer] {
        EditorInspectorOrdering.visibleLayersTopFirst(annotation.layers.elements)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("图层（\(listedLayers.count)）")
                .font(.headline)
                .padding(.horizontal, DS.s3)
                .padding(.vertical, DS.s3 - 2)
            Divider()

            if listedLayers.isEmpty {
                VStack(spacing: DS.s3) {
                    Image(systemName: "square.on.square.dashed")
                        .font(.system(size: DS.font24, weight: .light))
                        .foregroundStyle(.tertiary)
                    VStack(spacing: DS.s1) {
                        Text("还没有标注")
                            .font(.system(size: DS.font13, weight: .medium))
                        Text("从顶部选择工具，然后在图片上拖拽。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(DS.s4)
            } else {
                List(selection: selectionBinding) {
                    ForEach(listedLayers) { layer in
                        HStack(spacing: DS.s2) {
                            Image(systemName: layer.kind.symbolName)
                                .foregroundStyle(Color(
                                    .sRGB,
                                    red: layer.color.r,
                                    green: layer.color.g,
                                    blue: layer.color.b,
                                    opacity: 1
                                ))
                            Text(layer.kind.displayName).font(.caption)
                            Spacer()
                            Button {
                                annotation.select(layer.id)
                                model.deleteSelected()
                            } label: {
                                Image(systemName: "trash").font(.caption2)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("删除\(layer.kind.displayName)图层")
                        }
                        .tag(layer.id)
                        .accessibilityValue(
                            annotation.selectedID == layer.id ? "已选择" : ""
                        )
                        .accessibilityAddTraits(
                            annotation.selectedID == layer.id ? .isSelected : []
                        )
                    }
                }
                .listStyle(.inset)
            }

            if let selectedID = annotation.selectedID,
               let index = annotation.layers.firstIndex(id: selectedID),
               annotation.layers[index].kind == .text {
                Divider()
                VStack(alignment: .leading, spacing: DS.s2) {
                    Text("文字内容").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: textBinding(for: selectedID))
                        .font(.system(size: DS.font12))
                        .frame(height: DS.s5 * 2 + DS.s3)
                        .border(DS.borderDefault)
                        .focused(textFieldFocused)
                }
                .padding(DS.s3)
            }
        }
    }

    private var selectionBinding: Binding<UUID?> {
        Binding(get: { annotation.selectedID }, set: { annotation.select($0) })
    }

    private func textBinding(for id: UUID) -> Binding<String> {
        Binding(
            get: { annotation.layers.firstIndex(id: id).map { annotation.layers[$0].text } ?? "" },
            set: { annotation.setText(id: id, $0) }
        )
    }
}

private struct EditorHistoryPanel: View {

    @ObservedObject var model: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            historyContent
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: DS.s1) {
            HStack {
                Text("修订历史")
                    .font(.headline)
                Spacer()
                if !model.isViewingLatestRevision {
                    Button("回到最新版") {
                        model.loadLatestRevision()
                    }
                    .buttonStyle(.borderless)
                }
            }
            Text("原图始终不变。打开旧版本继续编辑时，会在末尾追加一个新版本。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(DS.s3)
    }

    @ViewBuilder
    private var historyContent: some View {
        if model.revisions.isEmpty {
            Text("暂无修订记录")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: DS.s1) {
                        ForEach(
                            EditorInspectorOrdering.newestFirstIndices(count: model.revisions.count),
                            id: \.self
                        ) { index in
                            historyRow(index: index, revision: model.revisions[index])
                                .id(index)
                        }
                    }
                    .padding(DS.s2)
                }
                .onAppear { scrollToLoadedRevision(proxy) }
                .onChange(of: model.loadedRevisionIndex) { _, _ in
                    scrollToLoadedRevision(proxy)
                }
                .onChange(of: model.revisions.map(\.id)) { _, _ in
                    scrollToLoadedRevision(proxy)
                }
            }
        }
    }

    private func scrollToLoadedRevision(_ proxy: ScrollViewProxy) {
        guard let index = model.loadedRevisionIndex,
              model.revisions.indices.contains(index) else { return }
        DispatchQueue.main.async {
            proxy.scrollTo(index, anchor: .top)
        }
    }

    private func historyRow(index: Int, revision: Revision) -> some View {
        let selected = model.loadedRevisionIndex == index
        let latest = index == model.revisions.indices.last
        let note = revision.note ?? (index == 0 ? "原始" : "编辑")
        return Button {
            model.switchToRevision(at: index)
        } label: {
            VStack(alignment: .leading, spacing: DS.s1) {
                HStack(spacing: DS.s2) {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? DS.accent : DS.dimPrimary)
                    Text("v\(index + 1)")
                        .font(.caption.monospacedDigit().weight(.semibold))
                    if latest {
                        Text("最新")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(DS.accent)
                    }
                    Spacer()
                    Text(revision.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                HStack {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Text("\(revision.layers.count) 层")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, DS.s2)
            .padding(.horizontal, DS.s2)
            .background(
                RoundedRectangle(cornerRadius: DS.radiusChip, style: .continuous)
                    .fill(selected ? DS.accentFillHistory : .clear)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("版本 v\(index + 1)，\(note)")
        .accessibilityValue(
            [
                latest ? "最新版本" : nil,
                selected ? "当前正在查看" : nil,
                revision.createdAt.formatted(date: .abbreviated, time: .shortened),
                "\(revision.layers.count) 层"
            ]
            .compactMap { $0 }
            .joined(separator: "，")
        )
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
