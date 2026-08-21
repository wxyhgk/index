import SwiftUI

// ============================================================
// MARK: - 剪贴板 tab（图库内第五个 destination）
//
// 网格卡片 + 右侧详情面板。复用 ClipboardHistoryStore 数据源，
// 和浮动面板共享去重/落盘逻辑，只是展示形态不同。
// ============================================================

struct ClipboardDestination: GalleryDestination {
    let id = "destination.clipboard"
    let title = "剪贴板"
    let symbol = "doc.on.clipboard"
    let order = 75

    func content() -> AnyView {
        AnyView(ClipboardContent())
    }

    func inspector() -> AnyView? {
        AnyView(ClipboardInspectorPanelHost())
    }
}

// MARK: - 中间内容：页头 + 网格

private struct ClipboardContent: View {

    @ObservedObject private var viewModel: ClipboardHistoryViewModel
    @ObservedObject private var selection = ClipboardSelection.shared
    private let store: ClipboardHistoryStore

    @State private var renameItem: ClipboardHistoryItem?
    @State private var renameText = ""

    init(store: ClipboardHistoryStore = .shared) {
        self.store = store
        _viewModel = ObservedObject(wrappedValue: .shared)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            grid
        }
        .floatingPanel()
        .onAppear { viewModel.refresh() }
        .alert("重命名", isPresented: Binding(
            get: { renameItem != nil },
            set: { if !$0 { renameItem = nil } }
        )) {
            TextField("名称", text: $renameText)
            Button("保存") {
                if let item = renameItem {
                    viewModel.rename(renameText, for: item)
                }
                renameItem = nil
            }
            Button("取消", role: .cancel) { renameItem = nil }
        } message: {
            Text("给这条剪贴板记录起个名字，方便以后查找")
        }
    }

    // MARK: 页头：标题 + 计数 + 类型过滤 + 搜索

    private var header: some View {
        HStack(alignment: .top, spacing: DS.s3) {
            VStack(alignment: .leading, spacing: DS.s1) {
                Text("剪贴板历史")
                    .font(.largeTitle.weight(.bold))
                    .lineLimit(1)
                Text("\(viewModel.filteredItems.count) 个项目")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Spacer(minLength: DS.s2)

            // 类型过滤
            HStack(spacing: DS.s1) {
                filterTab("全部", kind: nil)
                filterTab("文本", kind: .text)
                filterTab("图片", kind: .image)
                filterTab("文件", kind: .file)
            }

            // 搜索
            HStack(spacing: DS.s1) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: DS.font12))
                    .foregroundStyle(.tertiary)
                TextField("搜索", text: $viewModel.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: DS.font13))
                    .frame(width: 140)
                    .onChange(of: viewModel.query) { _ in
                        viewModel.searchChanged()
                    }
            }
            .padding(.horizontal, DS.s2)
            .padding(.vertical, DS.s1)
            .background(DS.iconPlaceholderFill, in: RoundedRectangle(cornerRadius: DS.radiusSmall))
        }
        .padding(.horizontal, DS.s5)
        .padding(.top, DS.s5)
        .padding(.bottom, DS.s3)
    }

    private func filterTab(_ title: String, kind: ClipboardHistoryKind?) -> some View {
        Button {
            viewModel.setTypeFilter(kind)
        } label: {
            Text(title)
                .font(.system(size: DS.font12, weight: viewModel.typeFilter == kind ? .semibold : .regular))
                .padding(.horizontal, DS.s2)
                .padding(.vertical, DS.s1)
                .background(
                    viewModel.typeFilter == kind
                        ? DS.accent.opacity(0.15)
                        : Color.clear,
                    in: RoundedRectangle(cornerRadius: DS.radiusSmall)
                )
                .foregroundStyle(viewModel.typeFilter == kind ? DS.accent : .secondary)
        }
        .buttonStyle(.plain)
    }

    // MARK: 网格

    @ViewBuilder
    private var grid: some View {
        let visible = viewModel.filteredItems
        if visible.isEmpty {
            ContentUnavailableView(
                viewModel.query.isEmpty ? "暂无剪贴板历史" : "没有匹配的结果",
                systemImage: "doc.on.clipboard",
                description: Text(viewModel.query.isEmpty ? "复制内容后会自动记录在这里" : "换个关键词试试")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 180), spacing: DS.s3)],
                    spacing: DS.s3
                ) {
                    ForEach(visible) { item in
                        ClipboardGridCard(
                            item: item,
                            thumbnail: item.id.flatMap { viewModel.imageThumbnails[$0] },
                            appIcon: item.sourceApp.flatMap { viewModel.appIcons[$0] },
                            isSelected: selection.selectedID == item.id
                        )
                        .onTapGesture {
                            selection.select(item.id)
                        }
                        .contextMenu {
                            Button("复制") { viewModel.copyBack(item) }
                            Button("重命名…") {
                                renameText = item.title ?? ""
                                renameItem = item
                            }
                            Button(item.isFavorite ? "取消收藏" : "收藏") { viewModel.toggleFavorite(item) }
                            Button(item.pinned ? "取消固定" : "固定") { viewModel.togglePin(item) }
                            Divider()
                            Button("删除", role: .destructive) {
                                viewModel.delete(item)
                                ClipboardSelection.shared.clearIf(item.id)
                            }
                        }
                    }
                }
                .padding(.horizontal, DS.s4)
                .padding(.vertical, DS.s3)
            }
        }
    }
}

// MARK: - 网格卡片（比浮动面板卡片稍小，适配网格）

struct ClipboardGridCard: View {

    let item: ClipboardHistoryItem
    let thumbnail: NSImage?
    let appIcon: NSImage?
    var isSelected: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            contentArea
            footer
        }
        .frame(height: 160)
        .background(DS.panelFill(.resting))
        .clipShape(RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous)
                .strokeBorder(isSelected ? DS.clipboardSelectedRing : DS.borderDefault, lineWidth: isSelected ? 2 : DS.strokeSubtle)
        )
        // .clipped() 只裁视觉，命中区域仍会超出 frame 挡住相邻卡片。
        // contentShape 把 hit testing 锁定在卡片实际 bounds 内。
        .contentShape(Rectangle())
    }

    private var headerBar: some View {
        CardHeaderBar(
            label: typeLabel,
            time: item.capturedAt,
            appIcon: appIcon,
            barColor: barColor,
            pinned: item.pinned
        )
    }

    @ViewBuilder
    private var contentArea: some View {
        switch item.kind {
        case .text:
            Text(item.text ?? item.summary ?? "")
                .font(.system(size: DS.font12))
                .lineLimit(4)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(DS.s2)
        case .image:
            if let thumbnail {
                // Color.clear 先占满可用空间，overlay 图片 .fill 居中裁剪，
                // 避免长图 intrinsic size 撑破 VStack 布局。
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(
                        Image(nsImage: thumbnail)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    )
                    .clipped()
            } else {
                placeholderIcon("photo")
            }
        case .file:
            placeholderIcon("doc")
        }
    }

    private var footer: some View {
        HStack(spacing: DS.s1) {
            Text(item.displayName)
                .font(.system(size: DS.font11, weight: .medium))
                .lineLimit(1)
            Spacer()
            Text(footerText)
                .font(.system(size: DS.font9))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(.horizontal, DS.s2)
        .padding(.vertical, DS.s1)
    }

    private func placeholderIcon(_ name: String) -> some View {
        VStack {
            Image(systemName: name)
                .font(.system(size: DS.font20))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var typeLabel: String {
        switch item.kind {
        case .text: return "文本"
        case .image: return "图片"
        case .file: return "文件"
        }
    }

    private var barColor: Color {
        switch item.kind {
        case .text: return DS.clipboardTextBar
        case .image: return DS.clipboardImageBar
        case .file: return DS.clipboardFileBar
        }
    }

    private var footerText: String {
        switch item.kind {
        case .text:
            let count = (item.text ?? "").count
            return "\(count) 个字符"
        case .image:
            return item.summary ?? "图片"
        case .file:
            return item.summary ?? "文件"
        }
    }
}

// MARK: - 剪贴板选中状态（独立于 GallerySelection）

@MainActor
final class ClipboardSelection: ObservableObject {
    static let shared = ClipboardSelection()
    @Published var selectedID: Int64?

    func select(_ id: Int64?) {
        selectedID = (selectedID == id) ? nil : id
    }

    func clearIf(_ id: Int64?) {
        if selectedID == id { selectedID = nil }
    }
}
