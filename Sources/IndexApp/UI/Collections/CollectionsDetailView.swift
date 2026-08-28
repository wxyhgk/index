import SwiftUI

// ============================================================
// MARK: - 收藏 tab detail 布局
//
// 返回按钮 + 标题 + 计数，下方按 route 分发：
//   · shot detail：GalleryGrid + GalleryInspectorPanel
//   · clipboard detail：ClipboardFavoritesGrid + ClipboardInspectorPanelHost
// ============================================================

struct CollectionsDetailView: View {
    let store: ShotStore
    let viewModel: GalleryViewModel
    let route: CollectionsNavigationState.Route
    let collections: [ShotCollectionSummary]
    let clipboardFavorites: [ClipboardHistoryItem]
    let collectionClipboardItems: [ClipboardHistoryItem]
    let onClose: () -> Void

    @AppStorage(PagePreferences.galleryInspectorShown.key)
    private var showInspector = PagePreferences.galleryInspectorShown.defaultValue
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var gallerySelection: GallerySelection
    @StateObject private var clipboardSession: ClipboardPageSession
    @ObservedObject private var clipboardSelection: ClipboardSelection

    init(
        store: ShotStore,
        viewModel: GalleryViewModel,
        route: CollectionsNavigationState.Route,
        collections: [ShotCollectionSummary],
        clipboardFavorites: [ClipboardHistoryItem],
        collectionClipboardItems: [ClipboardHistoryItem],
        clipboardSession: ClipboardPageSession? = nil,
        onClose: @escaping () -> Void
    ) {
        self.store = store
        self.viewModel = viewModel
        self.route = route
        self.collections = collections
        self.clipboardFavorites = clipboardFavorites
        self.collectionClipboardItems = collectionClipboardItems
        self.onClose = onClose

        let resolvedSession = clipboardSession ?? ClipboardPageSession()
        resolvedSession.setScopedItems(Self.clipboardItems(
            for: route,
            favorites: clipboardFavorites,
            collectionItems: collectionClipboardItems
        ))
        _clipboardSession = StateObject(wrappedValue: resolvedSession)
        _clipboardSelection = ObservedObject(wrappedValue: resolvedSession.selection)
    }

    var body: some View {
        HStack(alignment: .top, spacing: DS.Shell.panelGap) {
            VStack(alignment: .leading, spacing: 0) {
                detailHeader
                content
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .floatingPanel()

            if showInspector {
                inspector
                    .frame(width: DS.Shell.inspectorWidth)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(DS.Motion.standard(reduced: reduceMotion), value: showInspector)
        .onAppear { synchronizeClipboardSession() }
        .onChange(of: route) { _, _ in synchronizeClipboardSession() }
        .onChange(of: clipboardFavorites) { _, _ in synchronizeClipboardSession() }
        .onChange(of: collectionClipboardItems) { _, _ in synchronizeClipboardSession() }
        .onChange(of: gallerySelection.generation) { _, _ in
            if gallerySelection.primaryID != nil {
                clipboardSelection.clear()
            }
        }
    }

    // MARK: 内容分支

    @ViewBuilder
    private var content: some View {
        switch route {
        case .favorites:
            GalleryGrid(
                store: store,
                viewModel: viewModel,
                scope: scope,
                chrome: .libraryPanel
            )
        case .collection:
            VStack(spacing: 0) {
                GalleryGrid(
                    store: store,
                    viewModel: viewModel,
                    scope: scope,
                    chrome: .libraryPanel
                )
                if !clipboardSession.visibleItems.isEmpty {
                    collectionClipboardSection
                }
            }
        case .clipboardFavorites:
            clipboardFavoritesSection
        }
    }

    /// 专题集里的剪贴板成员：和截图网格同样的布局，无分区标识。
    private var collectionClipboardSection: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 180), spacing: DS.s4)],
                spacing: DS.s4
            ) {
                ForEach(clipboardSession.visibleItems) { item in
                    clipboardCard(for: item)
                }
            }
            .padding(.horizontal, DS.s4)
            .padding(.vertical, DS.s3)
        }
    }

    @ViewBuilder
    private var clipboardFavoritesSection: some View {
        if clipboardSession.visibleItems.isEmpty {
            ContentUnavailableView(
                "暂无剪贴板收藏",
                systemImage: "doc.on.clipboard",
                description: Text("在剪贴板 tab 右键条目选择「收藏」即可加入")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 180), spacing: DS.s3)],
                    spacing: DS.s3
                ) {
                    ForEach(clipboardSession.visibleItems) { item in
                        clipboardCard(for: item)
                    }
                }
                .padding(.horizontal, DS.s4)
                .padding(.vertical, DS.s3)
            }
        }
    }

    private func clipboardCard(for item: ClipboardHistoryItem) -> some View {
        ClipboardGridCard(
            item: item,
            isSelected: clipboardSelection.selectedID == item.id,
            store: clipboardSession.viewModel.store
        )
        .equatable()
        .onTapGesture {
            clipboardSelection.select(item.id)
            if clipboardSelection.selectedID != nil {
                gallerySelection.select(only: nil)
            }
        }
        .contextMenu {
            Button("复制") {
                clipboardSession.viewModel.copyBack(item)
            }
            Button(item.isFavorite ? "取消收藏" : "收藏") {
                clipboardSession.viewModel.toggleFavorite(item)
                var updated = item
                updated.isFavorite.toggle()
                if route == .clipboardFavorites, !updated.isFavorite {
                    clipboardSession.removeScopedItem(item)
                } else {
                    clipboardSession.updateScopedItem(updated)
                }
            }
            Divider()
            Button("删除", role: .destructive) {
                clipboardSession.viewModel.delete(item)
                clipboardSession.removeScopedItem(item)
            }
        }
    }

    @ViewBuilder
    private var inspector: some View {
        switch route {
        case .favorites:
            GalleryInspectorPanel(isPresented: $showInspector, store: store, viewModel: viewModel)
        case .collection:
            if clipboardSession.selectedItem != nil {
                ClipboardInspectorPanel(isPresented: $showInspector, session: clipboardSession)
            } else {
                GalleryInspectorPanel(isPresented: $showInspector, store: store, viewModel: viewModel)
            }
        case .clipboardFavorites:
            ClipboardInspectorPanel(isPresented: $showInspector, session: clipboardSession)
        }
    }

    private func synchronizeClipboardSession() {
        clipboardSession.setScopedItems(Self.clipboardItems(
            for: route,
            favorites: clipboardFavorites,
            collectionItems: collectionClipboardItems
        ))
    }

    private static func clipboardItems(
        for route: CollectionsNavigationState.Route,
        favorites: [ClipboardHistoryItem],
        collectionItems: [ClipboardHistoryItem]
    ) -> [ClipboardHistoryItem] {
        switch route {
        case .favorites: return []
        case .collection: return collectionItems
        case .clipboardFavorites: return favorites
        }
    }

    // MARK: 页头

    private var detailHeader: some View {
        HStack(spacing: DS.s3) {
            Button(action: onClose) {
                Label("收藏", systemImage: "chevron.left")
                    .font(.system(size: DS.font13, weight: .medium))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])

            Image(systemName: symbol)
                .font(.system(size: DS.font24, weight: .medium))
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: DS.s1 / 2) {
                Text(title)
                    .font(.title2.weight(.bold))
                    .lineLimit(1)
                Text(count)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer()
        }
        .padding(.horizontal, DS.s5)
        .padding(.top, DS.s4)
        .padding(.bottom, DS.s2)
    }

    // MARK: 路由元信息

    private var symbol: String {
        switch route {
        case .favorites: return "star.fill"
        case .collection: return "rectangle.stack.fill"
        case .clipboardFavorites: return "doc.on.clipboard"
        }
    }

    private var color: Color {
        switch route {
        case .favorites: return .yellow
        case .collection: return .accentColor
        case .clipboardFavorites: return DS.clipboardImageBar
        }
    }

    private var title: String {
        switch route {
        case .favorites: return "快速收藏"
        case .collection(let id): return collections.first { $0.id == id }?.name ?? "收藏集"
        case .clipboardFavorites: return "剪贴板收藏"
        }
    }

    private var count: String {
        switch route {
        case .favorites, .collection:
            return "\(viewModel.displayShots.count) 张图片"
        case .clipboardFavorites:
            return "\(clipboardFavorites.count) 个项目"
        }
    }

    private var scope: GalleryContentScope {
        switch route {
        case .favorites: return .favorites
        case .collection(let id): return .collection(id: id, title: title)
        case .clipboardFavorites: return .favorites
        }
    }
}
