import SwiftUI

// ============================================================
// MARK: - 剪贴板详情面板（右侧 inspector）
//
// 选中卡片后显示完整内容：文本全文 / 图片大图 / 文件列表。
// 底部操作按钮：复制 / 固定 / 删除。
// ============================================================

struct ClipboardInspectorPanelHost: View {

    @AppStorage("galleryInspectorShown") private var showInspector = true

    var body: some View {
        ClipboardInspectorPanel(isPresented: $showInspector)
    }
}

struct ClipboardInspectorPanel: View {

    @Binding var isPresented: Bool

    @ObservedObject private var selection = ClipboardSelection.shared
    @ObservedObject private var viewModel: ClipboardHistoryViewModel
    private let store: ClipboardHistoryStore

    init(
        isPresented: Binding<Bool>,
        store: ClipboardHistoryStore = .shared
    ) {
        self._isPresented = isPresented
        self.store = store
        _viewModel = ObservedObject(wrappedValue: .shared)
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .scrollContentBackground(.hidden)
            .overlay(alignment: .topTrailing) {
                PanelCloseButton(label: "隐藏详情栏") { isPresented = false }
                    .padding(DS.s2)
            }
            .floatingPanel()
    }

    @ViewBuilder
    private var content: some View {
        if let item = selectedItem {
            detail(for: item)
        } else {
            ContentUnavailableView(
                "未选择剪贴板",
                systemImage: "doc.on.clipboard",
                description: Text("在网格中选择一条记录查看详情")
            )
        }
    }

    private var selectedItem: ClipboardHistoryItem? {
        guard let id = selection.selectedID else { return nil }
        return viewModel.filteredItems.first { $0.id == id }
    }

    // MARK: 详情内容

    private func detail(for item: ClipboardHistoryItem) -> some View {
        VStack(alignment: .leading, spacing: DS.s3) {
            // 元信息头
            HStack(spacing: DS.s2) {
                Text(typeLabel(for: item))
                    .font(.system(size: DS.font12, weight: .semibold))
                    .padding(.horizontal, DS.s2)
                    .padding(.vertical, DS.s1 / 2)
                    .background(barColor(for: item), in: RoundedRectangle(cornerRadius: DS.radiusSmall))
                Text(absoluteTimeString(for: item.capturedAt))
                    .font(.system(size: DS.font11))
                    .foregroundStyle(.secondary)
                if let app = item.sourceApp {
                    Text("· \(app)")
                        .font(.system(size: DS.font11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if item.pinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: DS.font11))
                        .foregroundStyle(DS.accent)
                }
            }

            // 内容区
            ScrollView {
                contentArea(for: item)
            }
            .scrollContentBackground(.hidden)

            Spacer(minLength: 0)

            // 操作按钮
            HStack(spacing: DS.s2) {
                Button {
                    viewModel.copyBack(item)
                } label: {
                    Label("复制", systemImage: "doc.on.doc")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button {
                    viewModel.togglePin(item)
                } label: {
                    Label(item.pinned ? "取消固定" : "固定", systemImage: item.pinned ? "pin.slash" : "pin")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    viewModel.delete(item)
                    selection.clearIf(item.id)
                } label: {
                    Label("删除", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.red)
            }
        }
        .padding(DS.s4)
    }

    @ViewBuilder
    private func contentArea(for item: ClipboardHistoryItem) -> some View {
        switch item.kind {
        case .text:
            Text(item.text ?? item.summary ?? "")
                .font(.system(size: DS.font13))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(DS.s3)
                .background(DS.iconPlaceholderFill, in: RoundedRectangle(cornerRadius: DS.radiusCard))
        case .image:
            if let id = item.id, let image = viewModel.imageThumbnails[id] {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: DS.radiusCard))
            } else {
                Label("图片加载失败", systemImage: "photo")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(DS.s4)
            }
        case .file:
            fileContent(for: item)
        }
    }

    @ViewBuilder
    private func fileContent(for item: ClipboardHistoryItem) -> some View {
        if let url = store.content(of: item).assetURL,
           let data = try? Data(contentsOf: url),
           let paths = try? JSONDecoder().decode([String].self, from: data) {
            VStack(alignment: .leading, spacing: DS.s2) {
                ForEach(paths, id: \.self) { path in
                    HStack(spacing: DS.s2) {
                        Image(systemName: "doc")
                            .foregroundStyle(.secondary)
                        Text((path as NSString).lastPathComponent)
                            .font(.system(size: DS.font12))
                            .lineLimit(1)
                        Spacer()
                        Text((path as NSString).deletingLastPathComponent)
                            .font(.system(size: DS.font10))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
            }
            .padding(DS.s3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DS.iconPlaceholderFill, in: RoundedRectangle(cornerRadius: DS.radiusCard))
        } else {
            Label(item.summary ?? "文件", systemImage: "doc")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(DS.s4)
        }
    }

    // MARK: 工具

    private func typeLabel(for item: ClipboardHistoryItem) -> String {
        switch item.kind {
        case .text: return "文本"
        case .image: return "图片"
        case .file: return "文件"
        }
    }

    private func barColor(for item: ClipboardHistoryItem) -> Color {
        switch item.kind {
        case .text: return DS.clipboardTextBar
        case .image: return DS.clipboardImageBar
        case .file: return DS.clipboardFileBar
        }
    }

    private func absoluteTimeString(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
