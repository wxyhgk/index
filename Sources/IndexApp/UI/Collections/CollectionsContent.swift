import SwiftUI

// ============================================================
// MARK: - 收藏 tab 组合器
//
// 持有所有 @State、数据加载、CRUD 逻辑和路由分发。
// 布局拆在 CollectionsOverviewView / CollectionsDetailView，
// 卡片组件拆在 CollectionCards / ClipboardFavoritesViews。
// ============================================================

struct CollectionsContent: View {
    @ObservedObject var store: ShotStore
    @ObservedObject var viewModel: GalleryViewModel
    @ObservedObject var navigation = CollectionsNavigationState.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var collections: [ShotCollectionSummary] = []
    @State private var favoritePreviews: [Shot] = []
    @State private var creating = false
    @State private var newName = ""
    @State private var renameTarget: ShotCollectionSummary?
    @State private var renameName = ""
    @State private var deleteTarget: ShotCollectionSummary?
    @State private var errorMessage: String?
    @State private var clipboardFavorites: [ClipboardHistoryItem] = []
    @State private var clipboardFavoritesThumbnails: [Int64: NSImage] = [:]
    @State private var clipboardFavoritesAppIcons: [String: NSImage] = [:]
    @State private var collectionClipboardItems: [ClipboardHistoryItem] = []
    @State private var collectionClipboardThumbnails: [Int64: NSImage] = [:]
    @State private var collectionClipboardAppIcons: [String: NSImage] = [:]

    init(store: ShotStore = .shared, viewModel: GalleryViewModel? = nil) {
        _store = ObservedObject(wrappedValue: store)
        let resolvedViewModel = viewModel
            ?? .resolve(for: store)
        _viewModel = ObservedObject(wrappedValue: resolvedViewModel)
    }

    var body: some View {
        Group {
            if let route = navigation.route {
                CollectionsDetailView(
                    store: store,
                    viewModel: viewModel,
                    route: route,
                    collections: collections,
                    clipboardFavorites: clipboardFavorites,
                    clipboardFavoritesThumbnails: clipboardFavoritesThumbnails,
                    clipboardFavoritesAppIcons: clipboardFavoritesAppIcons,
                    collectionClipboardItems: collectionClipboardItems,
                    collectionClipboardThumbnails: collectionClipboardThumbnails,
                    collectionClipboardAppIcons: collectionClipboardAppIcons,
                    onClose: closeDetail
                )
            } else {
                CollectionsOverviewView(
                    store: store,
                    viewModel: viewModel,
                    collections: collections,
                    favoritePreviews: favoritePreviews,
                    clipboardFavorites: clipboardFavorites,
                    clipboardFavoritesThumbnails: clipboardFavoritesThumbnails,
                    clipboardFavoritesAppIcons: clipboardFavoritesAppIcons,
                    creating: $creating,
                    newName: $newName,
                    renameTarget: $renameTarget,
                    renameName: $renameName,
                    deleteTarget: $deleteTarget,
                    errorMessage: $errorMessage,
                    filteredCollections: filteredCollections,
                    onOpen: open,
                    onCreate: createCollection,
                    onCommitRename: commitRename
                )
            }
        }
        .task { reload() }
        .onReceive(store.libraryDidChangePublisher) { reload() }
        .onDisappear {
            clearScopedFilter()
            navigation.route = nil
        }
        .alert("重命名收藏集", isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )) {
            TextField("收藏集名称", text: $renameName)
            Button("取消", role: .cancel) { renameTarget = nil }
            Button("保存") { commitRename() }
        }
        .confirmationDialog(
            "删除收藏集？",
            isPresented: Binding(
                get: { deleteTarget != nil },
                set: { if !$0 { deleteTarget = nil } }
            ),
            presenting: deleteTarget
        ) { target in
            Button("删除“\(target.name)”", role: .destructive) {
                viewModel.deleteCollection(id: target.id)
                deleteTarget = nil
                reload()
            }
            Button("取消", role: .cancel) {}
        } message: { _ in
            Text("只会删除专题集和归类关系，不会删除其中的截图。")
        }
    }

    // MARK: 数据加载

    private func reload() {
        collections = store.collectionSummaries()
        favoritePreviews = store.favoritePreviews()
        if case .collection(let id) = navigation.route,
           !collections.contains(where: { $0.id == id }) {
            clearScopedFilter()
            navigation.route = nil
        }
        reloadClipboardFavorites()
        reloadCollectionClipboardItems()
    }

    /// 当前打开的专题集里的剪贴板成员（截图成员由 GalleryGrid 走 viewModel 渲染）。
    private func reloadCollectionClipboardItems() {
        guard case .collection(let id) = navigation.route else {
            collectionClipboardItems = []
            return
        }
        let items = (try? ClipboardHistoryStore.shared.items(inCollection: id)) ?? []
        collectionClipboardItems = items
        for item in items where item.kind == .image {
            guard let id = item.id, collectionClipboardThumbnails[id] == nil,
                  let url = ClipboardHistoryStore.shared.content(of: item).assetURL,
                  let image = NSImage(contentsOf: url) else { continue }
            collectionClipboardThumbnails[id] = image
        }
        for item in items {
            guard let app = item.sourceApp, collectionClipboardAppIcons[app] == nil else { continue }
            Task {
                guard let icon = await AppIconProvider.shared.icon(forName: app) else { return }
                collectionClipboardAppIcons[app] = icon
            }
        }
    }

    private func reloadClipboardFavorites() {
        let favs = (try? ClipboardHistoryStore.shared.favorites()) ?? []
        clipboardFavorites = favs
        for item in favs where item.kind == .image {
            guard let id = item.id, clipboardFavoritesThumbnails[id] == nil,
                  let url = ClipboardHistoryStore.shared.content(of: item).assetURL,
                  let image = NSImage(contentsOf: url) else { continue }
            clipboardFavoritesThumbnails[id] = image
        }
        for item in favs {
            guard let app = item.sourceApp, clipboardFavoritesAppIcons[app] == nil else { continue }
            Task {
                guard let icon = await AppIconProvider.shared.icon(forName: app) else { return }
                clipboardFavoritesAppIcons[app] = icon
            }
        }
    }

    // MARK: CRUD

    private func createCollection() {
        do {
            _ = try store.createCollection(name: newName)
            newName = ""
            creating = false
            errorMessage = nil
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func commitRename() {
        guard let target = renameTarget else { return }
        do {
            try store.renameCollection(id: target.id, to: renameName)
            renameTarget = nil
            errorMessage = nil
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: 路由

    private func open(_ route: CollectionsNavigationState.Route) {
        withAnimation(DS.Motion.standard(reduced: reduceMotion)) {
            if route != .clipboardFavorites {
                let scope = scope(for: route)
                scope.activate(in: viewModel)
            }
            navigation.route = route
        }
        // 导航到专题集时加载其剪贴板成员（reload 只在首次出现时执行，导航切换不会触发）。
        if case .collection = route {
            reloadCollectionClipboardItems()
        }
    }

    private func closeDetail() {
        withAnimation(DS.Motion.standard(reduced: reduceMotion)) {
            clearScopedFilter()
            navigation.route = nil
        }
    }

    private func clearScopedFilter() {
        let isFavoriteFilter = viewModel.filter == .favorites
        guard isFavoriteFilter || isCollectionFilter else { return }
        viewModel.reset()
    }

    private var isCollectionFilter: Bool {
        if case .collection = viewModel.filter { return true }
        return false
    }

    private func scope(for route: CollectionsNavigationState.Route) -> GalleryContentScope {
        switch route {
        case .favorites: return .favorites
        case .collection(let id): return .collection(id: id, title: title(for: route))
        case .clipboardFavorites: return .favorites
        }
    }

    private func title(for route: CollectionsNavigationState.Route) -> String {
        switch route {
        case .favorites: return "快速收藏"
        case .collection(let id): return collections.first { $0.id == id }?.name ?? "收藏集"
        case .clipboardFavorites: return "剪贴板收藏"
        }
    }

    private var filteredCollections: [ShotCollectionSummary] {
        let query = viewModel.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return collections }
        return collections.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.note.localizedCaseInsensitiveContains(query)
        }
    }
}
