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

    /// 无界面的命令入口（收藏/搜索结果等）复用这一实例执行 store 动作。
    /// 主窗口 Tab 与浮动面板各自拥有独立实例，避免筛选、选择和窗口生命周期联动。
    static let shared = ClipboardHistoryViewModel(store: .shared)

    let store: ClipboardHistoryStore

    @Published var items: [ClipboardHistoryItem] = []
    @Published var query = ""
    @Published var selectedIndex: Int = 0
    /// 搜索结果只是候选集；队列保存完整条目快照，因此选中项被搜索隐藏后
    /// 仍然可见、可移除、可粘贴，也不会因候选列表重排而改变顺序。
    @Published private(set) var pasteQueueItems: [ClipboardHistoryItem] = []
    @Published private(set) var pasteFeedback: String?
    @Published private(set) var isContinuousSelectionEnabled = false
    @Published var typeFilter: ClipboardHistoryKind? = nil
    @Published var collectionSummaries: [ShotCollectionSummary] = []
    @Published var collectionMemberships: [Int64: Set<Int64>] = [:]

    private var searchTask: Task<Void, Never>?
    private var autoSelectsCurrentWhenQueueEmpty = true
    /// 上次加载的 contentHash 集合；未变时跳过重复加载。
    private var lastLoadedHashes: Set<String> = []

    init(store: ClipboardHistoryStore) {
        self.store = store
    }

    var filteredItems: [ClipboardHistoryItem] {
        guard let typeFilter else { return items }
        return items.filter { $0.kind == typeFilter }
    }

    var selectedItemID: Int64? {
        let visible = filteredItems
        guard visible.indices.contains(selectedIndex) else { return nil }
        return visible[selectedIndex].id
    }

    var orderedSelectedIDs: [Int64] { pasteQueueItems.compactMap(\.id) }
    var selectedCount: Int { pasteQueueItems.count }

    func selectionOrdinal(for item: ClipboardHistoryItem) -> Int? {
        guard let id = item.id,
              let index = pasteQueueItems.firstIndex(where: { $0.id == id })
        else { return nil }
        return index + 1
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
            let focusedID = self.selectedItemID
            self.items = items
            self.lastLoadedHashes = newHashes
            self.collectionMemberships = memberships
            self.reconcilePasteQueueAfterRefresh(focusedID: focusedID)
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
        pasteFeedback = nil
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
            self.updateQueuedSnapshots(from: newItems)
            self.pasteFeedback = nil
        }
    }

    // MARK: 键盘导航

    func moveSelection(_ delta: Int, preservingQueue: Bool = false) {
        let count = filteredItems.count
        guard count > 0 else { return }
        selectedIndex = ((selectedIndex + delta) % count + count) % count
        if !preservingQueue {
            resetPasteQueueToCurrentItem()
        }
    }

    /// 普通浏览时点击替换队列；Command 点击或连续模式点击都会切换成员。
    func select(
        _ item: ClipboardHistoryItem,
        extending: Bool = false,
        continuingQueue: Bool = false
    ) {
        guard let index = filteredItems.firstIndex(where: { $0.id == item.id }) else { return }
        selectedIndex = index
        pasteFeedback = nil
        autoSelectsCurrentWhenQueueEmpty = true
        guard item.id != nil else {
            pasteQueueItems = []
            return
        }
        if extending || continuingQueue {
            if let existing = pasteQueueItems.firstIndex(where: { $0.id == item.id }) {
                pasteQueueItems.remove(at: existing)
                if pasteQueueItems.isEmpty { autoSelectsCurrentWhenQueueEmpty = false }
            } else {
                pasteQueueItems.append(item)
            }
        } else {
            pasteQueueItems = [item]
        }
    }

    func removeFromPasteQueue(_ item: ClipboardHistoryItem) {
        pasteQueueItems.removeAll { $0.id == item.id }
        pasteFeedback = nil
        if pasteQueueItems.isEmpty { autoSelectsCurrentWhenQueueEmpty = false }
    }

    func clearPasteQueue() {
        pasteQueueItems = []
        pasteFeedback = nil
        autoSelectsCurrentWhenQueueEmpty = false
    }

    /// 连续选择是显式模式，不能由“当前是否正在搜索”隐式推断。
    /// 关闭时立即回到当前候选的单选语义。
    func setContinuousSelectionEnabled(_ enabled: Bool) {
        guard enabled != isContinuousSelectionEnabled else { return }
        isContinuousSelectionEnabled = enabled
        pasteFeedback = nil
        if enabled {
            if pasteQueueItems.isEmpty {
                resetPasteQueueToCurrentItem()
            }
        } else {
            resetPasteQueueToCurrentItem()
        }
    }

    /// 按显式队列顺序写入一次剪贴板，然后只发送一次 Cmd+V。
    /// 文本用换行拼接；图片/文件使用系统的多条目剪贴板表示。
    func pasteSelected() {
        let selectedItems = pasteQueueItems
        guard !selectedItems.isEmpty else {
            pasteFeedback = "请先选择要粘贴的卡片"
            return
        }
        guard selectedItems.count > 1 else {
            paste(selectedItems[0])
            return
        }
        guard selectedItems.dropFirst().allSatisfy({ $0.kind == selectedItems[0].kind }) else {
            pasteFeedback = "文字、图片和文件暂不能混合一次粘贴"
            return
        }

        let didCopy: Bool
        switch selectedItems[0].kind {
        case .text:
            let texts = selectedItems.compactMap { store.content(of: $0).text }
            guard texts.count == selectedItems.count else {
                pasteFeedback = "部分文字内容已不可用"
                return
            }
            didCopy = Clipboard.copy(text: Self.joinedTexts(texts))

        case .image:
            let images = selectedItems.compactMap { item -> CGImage? in
                guard let url = store.content(of: item).assetURL else { return nil }
                return ImageCodec.load(from: url)
            }
            guard images.count == selectedItems.count else {
                pasteFeedback = "部分图片文件已不可用"
                return
            }
            didCopy = Clipboard.copy(images)

        case .file:
            var urls: [URL] = []
            for item in selectedItems {
                guard let itemURLs = fileURLs(for: item) else {
                    pasteFeedback = "部分文件记录已不可用"
                    return
                }
                urls.append(contentsOf: itemURLs)
            }
            didCopy = Clipboard.copy(fileURLs: urls)
        }

        guard didCopy else {
            pasteFeedback = "无法写入系统剪贴板"
            return
        }
        selectedItems.forEach(store.markUsed)
        pasteFeedback = nil
        ClipboardHistoryCoordinator.shared.performPaste()
    }

    nonisolated static func joinedTexts(_ texts: [String]) -> String {
        texts.joined(separator: "\n")
    }

    /// 鼠标双击直接粘贴命中的记录，不能再通过可能正在变化的 selectedIndex 回查。
    func paste(_ item: ClipboardHistoryItem) {
        guard copyBack(item) else {
            pasteFeedback = "这条记录的内容已不可用"
            return
        }
        pasteFeedback = nil
        ClipboardHistoryCoordinator.shared.performPaste()
    }

    func deleteSelected() {
        let visible = filteredItems
        guard selectedIndex < visible.count else { return }
        let item = visible[selectedIndex]
        removeFromPasteQueue(item)
        store.delete(item)
        if selectedIndex >= filteredItems.count {
            selectedIndex = max(0, filteredItems.count - 1)
        }
        refresh()
    }

    // MARK: 动作

    @discardableResult
    func copyBack(_ item: ClipboardHistoryItem) -> Bool {
        let content = store.content(of: item)
        let didCopy: Bool
        switch item.kind {
        case .text:
            guard let text = content.text else { return false }
            didCopy = Clipboard.copy(text: text)
        case .image:
            guard let url = content.assetURL, let image = ImageCodec.load(from: url) else {
                return false
            }
            didCopy = Clipboard.copy(image)
        case .file:
            guard let urls = fileURLs(for: item) else { return false }
            didCopy = Clipboard.copy(fileURLs: urls)
        }
        guard didCopy else { return false }
        store.markUsed(item)
        return true
    }

    private func resetPasteQueueToCurrentItem() {
        pasteFeedback = nil
        let visible = filteredItems
        guard visible.indices.contains(selectedIndex), visible[selectedIndex].id != nil else {
            pasteQueueItems = []
            return
        }
        pasteQueueItems = [visible[selectedIndex]]
        autoSelectsCurrentWhenQueueEmpty = true
    }

    /// 数据库有新记录时更新可见条目的快照；搜索中的缺席表示“不匹配”，不是删除。
    private func reconcilePasteQueueAfterRefresh(focusedID: Int64?) {
        updateQueuedSnapshots(from: items)
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let validIDs = Set(items.compactMap(\.id))
            pasteQueueItems.removeAll { item in
                guard let id = item.id else { return true }
                return !validIDs.contains(id)
            }
        }
        if let focusedID,
           let newIndex = filteredItems.firstIndex(where: { $0.id == focusedID }) {
            selectedIndex = newIndex
        } else {
            selectedIndex = 0
        }
        pasteFeedback = nil
        if pasteQueueItems.isEmpty, autoSelectsCurrentWhenQueueEmpty {
            resetPasteQueueToCurrentItem()
        }
    }

    private func updateQueuedSnapshots(from candidates: [ClipboardHistoryItem]) {
        let byID = Dictionary(uniqueKeysWithValues: candidates.compactMap { item in
            item.id.map { ($0, item) }
        })
        pasteQueueItems = pasteQueueItems.map { queued in
            guard let id = queued.id else { return queued }
            return byID[id] ?? queued
        }
    }

    private func fileURLs(for item: ClipboardHistoryItem) -> [URL]? {
        guard let url = store.content(of: item).assetURL,
              let data = try? Data(contentsOf: url),
              let paths = try? JSONDecoder().decode([String].self, from: data),
              !paths.isEmpty
        else { return nil }
        return paths.map { URL(fileURLWithPath: $0) }
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
        removeFromPasteQueue(item)
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

/// 图库「剪贴板」Tab 的会话边界。
///
/// 中间网格和右侧 Inspector 是两个 SwiftUI 兄弟子树，必须读取同一份列表、
/// 筛选和选中解析状态；浮动剪贴板面板则明确不使用这个会话。
@MainActor
final class ClipboardTabSession {
    static let shared = ClipboardTabSession()

    let viewModel: ClipboardHistoryViewModel

    init(store: ClipboardHistoryStore = .shared) {
        viewModel = ClipboardHistoryViewModel(store: store)
    }
}
