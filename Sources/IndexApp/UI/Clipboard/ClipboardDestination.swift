import AppKit
import SwiftUI

// ============================================================
// MARK: - 剪贴板 tab（图库内第五个 destination）
//
// 网格卡片 + 右侧详情面板。复用 ClipboardHistoryStore 数据源，
// 和浮动面板共享去重/落盘逻辑，只是展示形态不同。
// ============================================================

// MARK: - 中间内容：页头 + 网格

struct ClipboardContent: View {

    @ObservedObject private var session: ClipboardPageSession
    @ObservedObject private var viewModel: ClipboardHistoryViewModel
    @ObservedObject private var selection: ClipboardSelection
    @StateObject private var thumbnailPreheater: ViewportThumbnailPreheater
    private let store: ClipboardHistoryStore

    @State private var renameItem: ClipboardHistoryItem?
    @State private var renameDraft = ClipboardCardRenameDraft()
    @State private var collectionItem: ClipboardHistoryItem?
    @State private var columnCount = 4
    @State private var isScrolling = false
    @State private var isLiveResizing = false

    init(session: ClipboardPageSession) {
        self.store = session.viewModel.store
        _session = ObservedObject(wrappedValue: session)
        _viewModel = ObservedObject(wrappedValue: session.viewModel)
        _selection = ObservedObject(wrappedValue: session.selection)
        _thumbnailPreheater = StateObject(wrappedValue: ViewportThumbnailPreheater())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            grid
        }
        // ClipboardContent 只作为内容库子页使用。外层 ContentLibraryView 已经拥有
        // floatingPanel 表面；这里再画一层会形成双重圆角、双重背景，并让窗口缩放时
        // 多出一层无意义的合成与布局工作。
        .background(widthReader)
        .onAppear { viewModel.refresh() }
        .onDisappear { thumbnailPreheater.reset() }
        .task(id: GalleryThumbnailDatasetKey(
            keys: viewModel.filteredItems
                .filter { $0.kind == .image }
                .map { "\($0.viewportIdentity)#\($0.contentHash)" },
            columnCount: columnCount
        )) {
            thumbnailPreheater.configure(
                entries: viewModel.filteredItems.compactMap { item in
                    guard item.kind == .image,
                          let url = store.content(of: item).assetURL
                    else { return nil }
                    return ViewportThumbnailEntry(
                        identity: item.viewportIdentity,
                        key: item.thumbnailCacheKey,
                        url: url
                    )
                },
                columnCount: columnCount
            )
        }
        .onChange(of: isLiveResizing, initial: true) { _, resizing in
            thumbnailPreheater.setSuspended(resizing)
        }
        .sheet(item: $collectionItem) { item in
            CollectionPickerSheet(
                item: item,
                viewModel: viewModel
            )
            .frame(width: 360)
            .frame(minHeight: 320)
        }
    }

    // MARK: 页头：标题 + 计数 + 类型过滤 + 搜索

    private var header: some View {
        HStack(alignment: .top, spacing: DS.s3) {
            VStack(alignment: .leading, spacing: DS.s1) {
                Text("剪贴板历史")
                    .font(.title2.weight(.semibold))
                    .lineLimit(1)
                Text(viewModel.query.trimmingCharacters(in: .whitespaces).isEmpty
                    ? "\(viewModel.totalCount) 项"
                    : "\(viewModel.filteredItems.count) 项")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Spacer(minLength: DS.s2)

            ClipboardFilterBar(viewModel: viewModel, searchWidth: 140)
        }
        .padding(.horizontal, DS.s5)
        .padding(.top, DS.s5)
        .padding(.bottom, DS.s3)
    }

    // MARK: 网格

    private var widthReader: some View {
        GeometryReader { proxy in
            Color.clear
                .onChange(of: proxy.size.width, initial: true) { _, width in
                    applyWidth(width)
                }
                .onChange(of: isLiveResizing) { wasResizing, resizing in
                    if wasResizing && !resizing { applyWidth(proxy.size.width) }
                }
        }
    }

    private func applyWidth(_ width: CGFloat) {
        guard width > 0, !isLiveResizing else { return }
        let usable = max(1, width - 2 * DS.s4)
        let count = max(
            1,
            Int((usable + DS.s3) / (ClipboardCardMetrics.gridWidth + DS.s3))
        )
        if count != columnCount { columnCount = count }
    }

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
            RecyclingCardCollectionView(
                sections: [RecyclingCardSection(
                    id: "clipboard",
                    title: "",
                    items: visible
                )],
                columnCount: columnCount,
                fixedItemWidth: ClipboardCardMetrics.gridWidth,
                itemHeight: ClipboardCardMetrics.gridHeight,
                interitemSpacing: DS.s3,
                lineSpacing: DS.s3,
                contentInsets: NSEdgeInsets(
                    top: DS.s3,
                    left: DS.s4,
                    bottom: DS.s3,
                    right: DS.s4
                ),
                headerHeight: 0,
                pinsHeaders: false,
                handlesSelection: true,
                selectionHitTest: { _, point, size in
                    ClipboardCardInteractionZones.selectsCard(at: point, in: size)
                },
                scrollTarget: selection.selectedID,
                card: { item in clipboardCard(for: item) },
                header: { _ in EmptyView() },
                onDisplay: { item in
                    viewModel.loadMoreIfNeeded(reaching: item)
                    guard item.kind == .image else { return }
                    thumbnailPreheater.mounted(item.viewportIdentity)
                },
                onEndDisplay: { item in
                    guard item.kind == .image else { return }
                    thumbnailPreheater.unmounted(item.viewportIdentity)
                },
                onSelect: { item, _ in
                    selection.select(item.id)
                }
            )
            .modifier(GalleryInteractionTracker(
                isScrolling: $isScrolling,
                isLiveResizing: $isLiveResizing
            ))
            .environment(\.galleryIsScrolling, isScrolling)
            .environment(\.galleryDefersThumbnailLoading, isLiveResizing)
        }
    }

    private func clipboardCard(for item: ClipboardHistoryItem) -> some View {
        RecyclingCardHoverReader { nativeHover in
            ClipboardGridCard(
                item: item,
                isSelected: selection.selectedID == item.id,
                isHovering: nativeHover && !isScrolling,
                onToggleFavorite: { viewModel.toggleFavorite(item) },
                isRenaming: renameItem?.viewportIdentity == item.viewportIdentity,
                renameText: renameDraft.text,
                onRenameTextChange: { renameDraft.text = $0 },
                onBeginRename: { beginRenaming(item) },
                onCommitRename: { commitRenaming(item, title: $0) },
                onCancelRename: { cancelRenaming(item) },
                store: store
            )
            .equatable()
        }
        .environment(\.galleryIsScrolling, isScrolling)
        .environment(\.galleryDefersThumbnailLoading, isLiveResizing)
        .contextMenu {
            // NSCollectionView 会复用已经滚出/滚入的卡片。不能在滚动时返回空菜单，
            // 否则被复用的 hosting view 可能一直保留空 contextMenu。
            Button("复制") {
                selection.selectedID = item.id
                viewModel.copyBack(item)
            }
            Button("修改名称") { beginRenaming(item) }
            Button(item.isFavorite ? "取消收藏" : "收藏") {
                selection.selectedID = item.id
                viewModel.toggleFavorite(item)
            }
            Button(item.pinned ? "取消固定" : "固定") {
                selection.selectedID = item.id
                viewModel.togglePin(item)
            }
            collectionMenu(for: item)
            Divider()
            Button("删除", role: .destructive) {
                viewModel.delete(item)
                selection.clearIf(item.id)
            }
        }
    }

    private func beginRenaming(_ item: ClipboardHistoryItem) {
        if let activeItem = renameItem,
           activeItem.viewportIdentity != item.viewportIdentity {
            commitRenaming(activeItem)
        }
        renameDraft.text = item.title ?? ""
        renameItem = item
    }

    private func commitRenaming(_ item: ClipboardHistoryItem, title: String? = nil) {
        guard renameItem?.viewportIdentity == item.viewportIdentity else { return }
        if let title { renameDraft.text = title }
        let committedTitle = renameDraft.text
        renameItem = nil
        renameDraft.text = ""
        viewModel.rename(committedTitle, for: item)
    }

    private func cancelRenaming(_ item: ClipboardHistoryItem) {
        guard renameItem?.viewportIdentity == item.viewportIdentity else { return }
        renameItem = nil
        renameDraft.text = ""
    }

    @ViewBuilder
    private func collectionMenu(for item: ClipboardHistoryItem) -> some View {
        let summaries = viewModel.collectionSummaries
        let memberships = item.id.flatMap { viewModel.collectionMemberships[$0] } ?? []
        if summaries.isEmpty {
            Text("尚无专题集，请先到「收藏」页创建")
                .disabled(true)
        } else if summaries.count <= 5 {
            // 少量集合：内联菜单直接选。
            Menu {
                ForEach(summaries) { collection in
                    let isIn = memberships.contains(collection.id)
                    Button {
                        viewModel.toggleCollectionMembership(item, collectionID: collection.id)
                    } label: {
                        Label(
                            collection.name,
                            systemImage: isIn ? "checkmark" : "rectangle.stack.badge.plus"
                        )
                    }
                }
            } label: {
                Label("加入专题收藏集", systemImage: "rectangle.stack.badge.plus")
            }
        } else {
            // 集合多：弹带搜索的 sheet。
            Button {
                collectionItem = item
            } label: {
                Label("加入专题收藏集…", systemImage: "rectangle.stack.badge.plus")
            }
        }
    }
}

// MARK: - 网格卡片（比浮动面板卡片稍小，适配网格）

struct ClipboardGridCard: View, Equatable {

    let item: ClipboardHistoryItem
    var isSelected: Bool = false
    var isHovering = false
    var onToggleFavorite: (() -> Void)? = nil
    var isRenaming = false
    var renameText = ""
    var onRenameTextChange: ((String) -> Void)? = nil
    var onBeginRename: (() -> Void)? = nil
    var onCommitRename: ((String) -> Void)? = nil
    var onCancelRename: (() -> Void)? = nil
    var store: ClipboardHistoryStore

    static func == (lhs: ClipboardGridCard, rhs: ClipboardGridCard) -> Bool {
        lhs.item == rhs.item
            && lhs.isSelected == rhs.isSelected
            && lhs.isHovering == rhs.isHovering
            && lhs.isRenaming == rhs.isRenaming
            && lhs.renameText == rhs.renameText
            && lhs.store === rhs.store
    }

    var body: some View {
        ClipboardCardBody(
            item: item,
            textLineLimit: 4,
            store: store,
            showsRenameAction: isHovering,
            isRenaming: isRenaming,
            renameText: renameText,
            onRenameTextChange: onRenameTextChange,
            onBeginRename: onBeginRename,
            onCommitRename: onCommitRename,
            onCancelRename: onCancelRename
        )
        .equatable()
        .overlay(alignment: .bottomTrailing) { favoriteButton }
        .frame(
            width: ClipboardCardMetrics.gridWidth,
            height: ClipboardCardMetrics.gridHeight
        )
        .modifier(ClipboardCardChrome(isSelected: isSelected, isHovering: isHovering))
    }

    /// 收藏星：悬停浮出，已收藏常显实心黄星。
    @ViewBuilder
    private var favoriteButton: some View {
        if let onToggleFavorite, (isHovering || item.isFavorite) {
            Button(action: onToggleFavorite) {
                Image(systemName: item.isFavorite ? "star.fill" : "star")
                    .font(.system(size: DS.font12, weight: .semibold))
                    .foregroundStyle(item.isFavorite ? .yellow : .primary)
                    .frame(width: 28, height: 28)
                    .background(DS.panelFill(.overlay).opacity(0.9), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .padding(DS.s1)
            .help(item.isFavorite ? "取消收藏" : "收藏")
        }
    }
}

// MARK: - 专题收藏集选择器（集合多时弹出，带搜索）

private struct CollectionPickerSheet: View {
    let item: ClipboardHistoryItem
    @ObservedObject var viewModel: ClipboardHistoryViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    private var summaries: [ShotCollectionSummary] { viewModel.collectionSummaries }
    private var memberships: Set<Int64> {
        item.id.flatMap { viewModel.collectionMemberships[$0] } ?? []
    }

    private var filtered: [ShotCollectionSummary] {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return summaries }
        return summaries.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            searchBar
            listSection
        }
    }

    private var headerBar: some View {
        HStack {
            Text("加入专题收藏集")
                .font(.headline)
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, DS.s4)
        .padding(.top, DS.s4)
        .padding(.bottom, DS.s2)
    }

    private var searchBar: some View {
        HStack(spacing: DS.s1) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: DS.font12))
                .foregroundStyle(.tertiary)
            TextField("搜索专题集", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: DS.font13))
        }
        .padding(.horizontal, DS.s2)
        .padding(.vertical, DS.s1)
        .background(DS.iconPlaceholderFill, in: RoundedRectangle(cornerRadius: DS.radiusSmall))
        .padding(.horizontal, DS.s4)
        .padding(.bottom, DS.s3)
    }

    @ViewBuilder
    private var listSection: some View {
        if filtered.isEmpty {
            ContentUnavailableView(
                searchText.isEmpty ? "尚无专题集" : "没有匹配的专题集",
                systemImage: "rectangle.stack",
                description: Text(searchText.isEmpty ? "请先到「收藏」页创建" : "换个关键词试试")
            )
            .frame(maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: DS.s1) {
                    ForEach(filtered) { collection in
                        row(for: collection)
                    }
                }
                .padding(.horizontal, DS.s3)
                .padding(.bottom, DS.s3)
            }
        }
    }

    private func row(for collection: ShotCollectionSummary) -> some View {
        let isIn = memberships.contains(collection.id)
        return Button {
            viewModel.toggleCollectionMembership(item, collectionID: collection.id)
        } label: {
            HStack(spacing: DS.s2) {
                Image(systemName: isIn ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: DS.font15))
                    .foregroundStyle(isIn ? AnyShapeStyle(DS.accent) : AnyShapeStyle(.tertiary))
                VStack(alignment: .leading, spacing: 1) {
                    Text(collection.name)
                        .font(.system(size: DS.font13, weight: .medium))
                        .lineLimit(1)
                    Text("\(collection.itemCount) 张")
                        .font(.system(size: DS.font11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isIn {
                    Text("已加入")
                        .font(.system(size: DS.font11))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, DS.s3)
            .padding(.vertical, DS.s2)
            .background(
                isIn ? DS.accent.opacity(0.08) : Color.clear,
                in: RoundedRectangle(cornerRadius: DS.radiusSmall)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
