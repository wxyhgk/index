import SwiftUI

/// 右侧面板（图层 / 效果 双 tab）。
struct EditorInspector: View {

    @ObservedObject var annotation: AnnotationState
    @ObservedObject var model: EditorModel
    var textFieldFocused: FocusState<Bool>.Binding

    private enum Tab: String, CaseIterable { case layers = "图层", effects = "效果" }
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
            }
        }
    }
}

/// 图层列表 + 文字编辑 + 历史版本。
private struct EditorLayersPanel: View {

    @ObservedObject var annotation: AnnotationState
    @ObservedObject var model: EditorModel
    var textFieldFocused: FocusState<Bool>.Binding

    private var listedLayers: [Layer] {
        annotation.layers.elements.filter { !$0.kind.isEffect }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("图层（\(listedLayers.count)）")
                .font(.headline)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            Divider()

            List(selection: selectionBinding) {
                ForEach(listedLayers) { layer in
                    HStack(spacing: 8) {
                        Image(systemName: layer.kind.symbolName)
                            .foregroundStyle(Color(.sRGB, red: layer.color.r, green: layer.color.g, blue: layer.color.b, opacity: 1))
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
                        .focused(textFieldFocused)
                }
                .padding(12)
            }

            Divider()
            historyPicker
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

    private var historyPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("历史版本").font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(model.revisions.enumerated()), id: \.element.id) { index, rev in
                        Button {
                            model.loadRevision(layers: rev.layers, index: index)
                        } label: {
                            HStack {
                                Text("v\(index + 1)").font(.caption.monospacedDigit())
                                Text(rev.note ?? "编辑").font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Text("\(rev.layers.count) 层").font(.caption2).foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 3).padding(.horizontal, 6)
                            .background(RoundedRectangle(cornerRadius: 4).fill(model.loadedRevisionIndex == index ? Color.accentColor.opacity(0.18) : .clear))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: 120)
        }
        .padding(12)
    }
}
