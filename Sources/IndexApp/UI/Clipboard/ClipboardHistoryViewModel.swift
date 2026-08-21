import AppKit
import Combine
import UniformTypeIdentifiers

// ============================================================
// MARK: - 剪贴板历史视图模型
//
// 数据加载、搜索、类型过滤、键盘导航、复制/删除/固定动作。
// ============================================================

@MainActor
final class ClipboardHistoryViewModel: ObservableObject {

    /// 主窗口 tab 和浮动面板共享同一个实例，避免数据不同步。
    static let shared = ClipboardHistoryViewModel(store: .shared)

    let store: ClipboardHistoryStore

    @Published var items: [ClipboardHistoryItem] = []
    @Published var query = ""
    @Published var imageThumbnails: [Int64: NSImage] = [:]
    @Published var appIcons: [String: NSImage] = [:]
    @Published var selectedIndex: Int = 0
    @Published var typeFilter: ClipboardHistoryKind? = nil
    @Published var collectionSummaries: [ShotCollectionSummary] = []
    @Published var collectionMemberships: [Int64: Set<Int64>] = [:]

    private var searchTask: Task<Void, Never>?
    private var thumbnailTask: Task<Void, Never>?
    /// 上次加载的 contentHash 集合；未变时跳过重复加载。
    private var lastLoadedHashes: Set<String> = []

    init(store: ClipboardHistoryStore) {
        self.store = store
    }

    var filteredItems: [ClipboardHistoryItem] {
        guard let typeFilter else { return items }
        return items.filter { $0.kind == typeFilter }
    }

    func refresh() {
        let store = self.store
        let query = self.query
        let collectionRepo = ShotStore.shared.collectionRepository
        Task { [weak self] in
            guard let self else { return }
            // 数据库查询全部在后台，不阻塞主线程渲染。
            async let newItems: [ClipboardHistoryItem] = Task.detached(priority: .userInitiated) {
                (try? store.recent(limit: 100, query: query.isEmpty ? nil : query)) ?? []
            }.value
            async let summaries: [ShotCollectionSummary] = Task.detached(priority: .utility) {
                (try? collectionRepo.summaries()) ?? []
            }.value

            let items = await newItems
            let collections = await summaries
            let ids = items.compactMap(\.id)
            let memberships = await Task.detached(priority: .utility) {
                store.collectionMemberships(clipboardIDs: ids)
            }.value

            guard !Task.isCancelled else { return }
            // 专题集列表不依赖剪贴板数据，每次 refresh 都更新（新建/删除专题集后立即可见）。
            self.collectionSummaries = collections

            let newHashes = Set(items.map(\.contentHash))
            if newHashes == self.lastLoadedHashes && !items.isEmpty {
                return
            }
            self.items = items
            self.lastLoadedHashes = newHashes
            self.collectionMemberships = memberships
            self.selectedIndex = 0
            self.loadThumbnails()
        }
    }

    func searchChanged() {
        searchTask?.cancel()
        let q = query.trimmingCharacters(in: .whitespaces)
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            self?.applyFilter(q)
        }
    }

    func setTypeFilter(_ kind: ClipboardHistoryKind?) {
        typeFilter = kind
        selectedIndex = 0
    }

    private func applyFilter(_ q: String) {
        let store = self.store
        Task { [weak self] in
            guard let self else { return }
            let newItems = await Task.detached(priority: .userInitiated) {
                (try? store.recent(limit: 100, query: q.isEmpty ? nil : q)) ?? []
            }.value
            guard !Task.isCancelled else { return }
            self.items = newItems
            self.lastLoadedHashes = Set(newItems.map(\.contentHash))
            self.selectedIndex = 0
            self.loadThumbnails()
        }
    }

    private func loadThumbnails() {
        thumbnailTask?.cancel()
        // 先清掉旧缩略图，避免切 tab 后残留上一批。
        imageThumbnails.removeAll()

        // 后台解码图片，逐张更新到主线程，不卡 UI。
        let imageItems = items.filter { $0.kind == .image && $0.id != nil }
        let urls: [(id: Int64, url: URL)] = imageItems.compactMap { item in
            guard let id = item.id, let url = store.content(of: item).assetURL else { return nil }
            return (id, url)
        }
        thumbnailTask = Task { [weak self] in
            for (id, url) in urls {
                guard !Task.isCancelled else { return }
                let image = await Task.detached(priority: .utility) {
                    NSImage(contentsOf: url)
                }.value
                guard let image, !Task.isCancelled else { continue }
                await MainActor.run {
                    self?.imageThumbnails[id] = image
                }
            }
        }

        // 来源 App 图标（标题栏右上角）：走共享 AppIconProvider，异步解析不卡主线程。
        for item in items {
            guard let app = item.sourceApp, appIcons[app] == nil else { continue }
            Task { [weak self] in
                guard let icon = await AppIconProvider.shared.icon(forName: app) else { return }
                self?.appIcons[app] = icon
            }
        }
    }

    // MARK: 键盘导航

    func moveSelection(_ delta: Int) {
        let count = filteredItems.count
        guard count > 0 else { return }
        selectedIndex = ((selectedIndex + delta) % count + count) % count
    }

    /// 粘贴选中项：复制到剪贴板，然后通知 Coordinator 执行关面板+恢复焦点+模拟 Cmd+V。
    func pasteSelected() {
        let visible = filteredItems
        guard selectedIndex < visible.count else { return }
        let item = visible[selectedIndex]
        copyBack(item)
        ClipboardHistoryCoordinator.shared.performPaste()
    }

    func deleteSelected() {
        let visible = filteredItems
        guard selectedIndex < visible.count else { return }
        let item = visible[selectedIndex]
        store.delete(item)
        if selectedIndex >= filteredItems.count {
            selectedIndex = max(0, filteredItems.count - 1)
        }
        refresh()
    }

    // MARK: 动作

    func copyBack(_ item: ClipboardHistoryItem) {
        let content = store.content(of: item)
        switch item.kind {
        case .text:
            if let text = content.text {
                Clipboard.copy(text: text)
            }
        case .image:
            if let url = content.assetURL, let image = ImageCodec.load(from: url) {
                Clipboard.copy(image)
            }
        case .file:
            if let url = content.assetURL,
               let data = try? Data(contentsOf: url),
               let paths = try? JSONDecoder().decode([String].self, from: data) {
                let urls = paths.map { URL(fileURLWithPath: $0) }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects(urls as [NSURL])
            }
        }
        store.markUsed(item)
    }

    /// 拖拽到目标应用：按类型提供 NSItemProvider（图片/文本/文件）。
    func dragProvider(for item: ClipboardHistoryItem) -> NSItemProvider {
        let content = store.content(of: item)
        let provider = NSItemProvider()
        switch item.kind {
        case .text:
            let text = content.text ?? ""
            provider.registerDataRepresentation(
                forTypeIdentifier: UTType.utf8PlainText.identifier,
                visibility: .all
            ) { completion in
                completion(text.data(using: .utf8), nil)
                return Progress()
            }
        case .image:
            guard let url = content.assetURL, FileManager.default.fileExists(atPath: url.path) else { return provider }
            // 同时注册 data（UTType.png）和 fileURL（UTType.fileURL），
            // 不同应用接受的方式不同：备忘录/微信接受 data，Finder 接受 fileURL。
            provider.registerDataRepresentation(
                forTypeIdentifier: UTType.png.identifier,
                visibility: .all
            ) { completion in
                completion(try? Data(contentsOf: url), nil)
                return Progress()
            }
            provider.registerFileRepresentation(
                forTypeIdentifier: UTType.fileURL.identifier,
                visibility: .all
            ) { completion in
                completion(url, true, nil)
                return Progress()
            }
        case .file:
            if let url = content.assetURL,
               let data = try? Data(contentsOf: url),
               let paths = try? JSONDecoder().decode([String].self, from: data) {
                let fileURLs = paths.map { URL(fileURLWithPath: $0) }
                provider.registerFileRepresentation(
                    forTypeIdentifier: UTType.fileURL.identifier,
                    visibility: .all
                ) { completion in
                    completion(fileURLs.first, true, nil)
                    return Progress()
                }
            }
        }
        return provider
    }

    func togglePin(_ item: ClipboardHistoryItem) {
        store.setPinned(!item.pinned, for: item)
        refresh()
    }

    func rename(_ title: String?, for item: ClipboardHistoryItem) {
        store.rename(title, for: item)
        refresh()
    }

    func toggleFavorite(_ item: ClipboardHistoryItem) {
        store.setFavorite(!item.isFavorite, for: item)
        refresh()
    }

    func delete(_ item: ClipboardHistoryItem) {
        store.delete(item)
        refresh()
    }

    // MARK: 专题收藏集

    func toggleCollectionMembership(_ item: ClipboardHistoryItem, collectionID: Int64) {
        guard let id = item.id else { return }
        let isIn = collectionMemberships[id]?.contains(collectionID) == true
        if isIn {
            store.removeFromCollection(clipboardID: id, collectionID: collectionID)
        } else {
            do {
                try store.addToCollection(clipboardID: id, collectionID: collectionID)
            } catch {
                NSLog("[Index] 剪贴板加入收藏集失败: \(error)")
                return
            }
        }
        // 只更新当前条目的成员关系，不整体 refresh（避免重查数据库 + 重解码图片）。
        var updated = collectionMemberships
        if isIn {
            updated[id]?.remove(collectionID)
        } else {
            updated[id, default: []].insert(collectionID)
        }
        collectionMemberships = updated
    }
}
