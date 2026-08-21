import SwiftUI

/// 编辑器顶部工具栏。
/// 从 `EditorView` 拆出的第一块独立视图，承载工具选择与样式轴。
struct EditorToolbar: View {

    @ObservedObject var annotation: AnnotationState
    @ObservedObject var model: EditorModel
    var textFieldFocused: FocusState<Bool>.Binding

    /// 唯一真相：跟覆盖层/钉图的 `ToolControl` 同源 `BuiltinTools.all`，声明顺序即展示顺序。
    private static var toolOrder: [AnnotationTool?] {
        [nil] + BuiltinTools.all.map(\.tool)
    }

    var body: some View {
        HStack(spacing: DS.s3) {
            Button {
                model.requestReturnToGallery()
            } label: {
                HStack(spacing: DS.s1 - 1) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: DS.font12, weight: .semibold))
                    Text("图库")
                }
                .frame(height: 44)
                .padding(.horizontal, DS.s2 - 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("返回图库（⎋）")

            Divider().frame(height: DS.s5)

            HStack(spacing: DS.s1 / 2) {
                toolButton(nil)
                handButton
                ForEach(Array(Self.toolOrder.dropFirst().enumerated()), id: \.offset) { _, tool in
                    toolButton(tool)
                }
            }

            Spacer(minLength: DS.s2)

            if annotation.styleAxes.contains(.color) {
                HStack(spacing: DS.s1) {
                    ForEach(AnnotationState.palette.indices, id: \.self) { index in
                        colorButton(index)
                    }
                }
                Divider().frame(height: DS.s4 + 2)
            }

            ForEach(annotation.styleAxes.filter { $0 != .color }, id: \.self) { axis in
                HStack(spacing: DS.s1) {
                    ForEach(axis.steps.indices, id: \.self) { index in
                        paramButton(axis, index)
                    }
                }
                Divider().frame(height: 18)
            }

            Button {
                model.undo()
            } label: {
                Image(systemName: "arrow.uturn.backward").frame(width: 26, height: 22)
            }
            .buttonStyle(.plain)
            .disabled(!annotation.canUndo)
            .keyboardShortcut("z", modifiers: .command)
            .help("撤销（⌘Z）")

            Button {
                model.redo()
            } label: {
                Image(systemName: "arrow.uturn.forward").frame(width: 26, height: 22)
            }
            .buttonStyle(.plain)
            .disabled(!annotation.canRedo)
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .help("重做（⇧⌘Z）")
        }
        .padding(.horizontal, DS.s4 - 2)
        .padding(.vertical, DS.s2 - 2)
    }

    private func toolButton(_ tool: AnnotationTool?) -> some View {
        let selected = annotation.tool == tool && model.canvasMode == .pointer
        let shortcut = AnnotationTool.shortcuts.first { $0.tool == tool }
        return Button {
            selectTool(tool)
        } label: {
            VStack(spacing: DS.s1 - 1) {
                Image(systemName: tool?.symbolName ?? "cursorarrow")
                    .font(.system(size: DS.font15))
                    .frame(height: 18)
                Text(tool?.title ?? "指针")
                    .font(.caption2)
            }
            .frame(width: 48, height: 44)
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: DS.radiusSmall)
                .fill(selected ? DS.accentFillSelected : .clear)
        )
        .foregroundStyle(selected ? DS.accent : .primary)
        .keyboardShortcut(bareKeyShortcut(shortcut?.label))
        .help(shortcut.map { "\($0.toolName)（\($0.label)）" } ?? tool?.title ?? "指针")
    }

    private var handButton: some View {
        let selected = model.canvasMode == .hand
        let disabled = model.zoomLevel == nil
        return Button {
            toggleHandMode()
        } label: {
            VStack(spacing: DS.s1 - 1) {
                Image(systemName: "hand.raised")
                    .font(.system(size: DS.font15))
                    .frame(height: 18)
                Text("抓手")
                    .font(.caption2)
            }
            .frame(width: 48, height: 44)
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: DS.radiusSmall)
                .fill(selected ? DS.accentFillSelected : .clear)
        )
        .foregroundStyle(selected ? DS.accent : .primary)
        .opacity(disabled ? 0.35 : 1)
        .disabled(disabled)
        .help(disabled
              ? "抓手：放大后可拖拽平移画布（按住空格临时抓手）"
              : "抓手：拖拽平移画布（按住空格临时抓手）")
    }

    private func toggleHandMode() {
        annotation.endTextEditing()
        if model.canvasMode == .hand {
            model.canvasMode = .pointer
        } else {
            model.canvasMode = .hand
            annotation.tool = nil
        }
    }

    private func bareKeyShortcut(_ label: String?) -> SwiftUI.KeyboardShortcut? {
        guard !textFieldFocused.wrappedValue,
              let ch = label?.lowercased().first else { return nil }
        return SwiftUI.KeyboardShortcut(KeyEquivalent(ch), modifiers: [])
    }

    private func colorButton(_ index: Int) -> some View {
        let c = AnnotationState.palette[index]
        let selected = annotation.styleIndex(for: .color) == index
        return Button {
            annotation.setStyleIndex(index, for: .color)
            annotation.applyColorToSelection()
        } label: {
            Circle()
                .fill(Color(.sRGB, red: c.r, green: c.g, blue: c.b))
                .overlay(Circle().strokeBorder(DS.swatchOutline))
                .frame(width: 14, height: 14)
                .padding(DS.s1 - 1)
                .overlay(
                    Circle().strokeBorder(
                        selected ? DS.accent : .clear,
                        lineWidth: 1.5
                    )
                )
        }
        .buttonStyle(.plain)
        .help("颜色 \(index + 1)")
    }

    private func paramButton(_ axis: ToolStyleAxis, _ index: Int) -> some View {
        let selected = annotation.styleIndex(for: axis) == index
        return Button {
            annotation.setStyleIndex(index, for: axis)
            annotation.applyStyleToSelection(axis)
        } label: {
            if let icon = axis.descriptor.editorIcon {
                icon(index, selected)
            } else {
                Circle()
                    .fill(selected ? DS.accent : DS.dimPrimary)
                    .frame(width: 5 + CGFloat(index) * 4, height: 5 + CGFloat(index) * 4)
                    .frame(width: 20, height: 20)
            }
        }
        .buttonStyle(.plain)
        .help("\(axis.title) \(index + 1)")
    }

    private func selectTool(_ tool: AnnotationTool?) {
        annotation.endTextEditing()
        annotation.tool = tool
        model.canvasMode = .pointer
    }
}
