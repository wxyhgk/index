import AppKit
import Combine
import UniformTypeIdentifiers

enum ClipboardWorkspaceMode: String, CaseIterable, Identifiable {
    case history
    case threads
    case capsules

    var id: String { rawValue }

    var title: String {
        switch self {
        case .history: return "历史"
        case .threads: return "线程"
        case .capsules: return "胶囊"
        }
    }

    var systemImage: String {
        switch self {
        case .history: return "clock.arrow.circlepath"
        case .threads: return "point.3.connected.trianglepath.dotted"
        case .capsules: return "shippingbox"
        }
    }
}

struct ClipboardCapsulePasteProgress: Equatable {
    let capsuleID: Int64
    let name: String
    let items: [ClipboardHistoryItem]
    var nextIndex: Int

    var progressLabel: String {
        "继续粘贴 \(nextIndex + 1)/\(items.count)"
    }
}

// ============================================================
// MARK: - 剪贴板历史视图模型
//
// 数据加载、搜索、类型过滤、键盘导航、复制/删除/固定动作。
// ============================================================

@MainActor
final class ClipboardHistoryViewModel: ObservableObject {
    private static let pageSize = 100

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
    @Published private(set) var hasMoreItems = false
    @Published private(set) var isLoadingMore = false
    @Published var workspaceMode: ClipboardWorkspaceMode = .history
    @Published private(set) var threads: [ClipboardThread] = []
    @Published private(set) var capsules: [ClipboardCapsuleSnapshot] = []
    @Published private(set) var activeCapsulePaste: ClipboardCapsulePasteProgress?
    @Published var capsuleQuery = ""
    @Published private(set) var editingCapsuleID: Int64?
    @Published private(set) var editingCapsuleName: String?

    private var searchTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var pageTask: Task<Void, Never>?
    private var pastePreparationTask: Task<Void, Never>?
    private var loadGeneration = 0
    private var autoSelectsCurrentWhenQueueEmpty = true
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

    var filteredCapsules: [ClipboardCapsuleSnapshot] {
        let trimmed = capsuleQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return capsules }
        return capsules.filter { snapshot in
            snapshot.capsule.name.lowercased().contains(trimmed)
                || snapshot.items.contains { item in
                    item.displayName.lowercased().contains(trimmed)
                        || item.sourceApp?.lowercased().contains(trimmed) == true
                }
        }
    }

    func selectionOrdinal(for item: ClipboardHistoryItem) -> Int? {
        guard let id = item.id,
              let index = pasteQueueItems.firstIndex(where: { $0.id == id })
        else { return nil }
        return index + 1
    }

    func refresh() {
        loadGeneration &+= 1
        let generation = loadGeneration
        refreshTask?.cancel()
        searchTask?.cancel()
        pageTask?.cancel()
        isLoadingMore = false
        let store = self.store
        let query = self.query
        let pageLimit = Self.pageSize + 1
        let collectionRepo = ShotStore.shared.collectionRepository
        refreshTask = Task { [weak self] in
            guard let self else { return }
            // 数据库查询全部在后台，不阻塞主线程渲染。
            async let newItems: [ClipboardHistoryItem] = Task.detached(priority: .userInitiated) {
                (try? store.recent(
                    limit: pageLimit,
                    query: query.isEmpty ? nil : query
                )) ?? []
            }.value
            async let summaries: [ShotCollectionSummary] = Task.detached(priority: .utility) {
                (try? collectionRepo.summaries()) ?? []
            }.value
            async let capsuleSnapshots: [ClipboardCapsuleSnapshot] = Task.detached(priority: .utility) {
                (try? store.capsuleSnapshots()) ?? []
            }.value

            var items = await newItems
            let hasMore = items.count > Self.pageSize
            if hasMore { items.removeLast(items.count - Self.pageSize) }
            let collections = await summaries
            let capsules = await capsuleSnapshots
            let threads = await Task.detached(priority: .utility) {
                ClipboardThreadBuilder.build(from: items)
            }.value
            let ids = items.compactMap(\.id)
            let memberships = await Task.detached(priority: .utility) {
                store.collectionMemberships(clipboardIDs: ids)
            }.value

            guard !Task.isCancelled, generation == self.loadGeneration else { return }
            // 专题集列表不依赖剪贴板数据，每次 refresh 都更新（新建/删除专题集后立即可见）。
            self.collectionSummaries = collections
            self.capsules = capsules
            self.threads = threads

            let focusedID = self.selectedItemID
            self.items = items
            self.hasMoreItems = hasMore
            self.collectionMemberships = memberships
            self.reconcilePasteQueueAfterRefresh(focusedID: focusedID)
        }
    }

    func searchChanged() {
        searchTask?.cancel()
        refreshTask?.cancel()
        pageTask?.cancel()
        isLoadingMore = false
        loadGeneration &+= 1
        let generation = loadGeneration
        let q = query.trimmingCharacters(in: .whitespaces)
        let store = self.store
        let pageLimit = Self.pageSize + 1
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard let self else { return }
            let newItems = await Task.detached(priority: .userInitiated) {
                (try? store.recent(
                    limit: pageLimit,
                    query: q.isEmpty ? nil : q
                )) ?? []
            }.value
            guard !Task.isCancelled,
                  generation == self.loadGeneration,
                  self.query.trimmingCharacters(in: .whitespaces) == q
            else { return }
            let hasMore = newItems.count > Self.pageSize
            let items = Array(newItems.prefix(Self.pageSize))
            let threads = await Task.detached(priority: .utility) {
                ClipboardThreadBuilder.build(from: items)
            }.value
            guard !Task.isCancelled,
                  generation == self.loadGeneration,
                  self.query.trimmingCharacters(in: .whitespaces) == q
            else { return }
            self.items = items
            self.threads = threads
            self.hasMoreItems = hasMore
            self.selectedIndex = 0
            self.updateQueuedSnapshots(from: newItems)
            self.pasteFeedback = nil
        }
    }

    func setTypeFilter(_ kind: ClipboardHistoryKind?) {
        typeFilter = kind
        selectedIndex = 0
        pasteFeedback = nil
    }

    func loadMoreIfNeeded(reaching item: ClipboardHistoryItem) {
        guard hasMoreItems,
              !isLoadingMore,
              filteredItems.last?.id == item.id,
              let tail = items.last,
              let tailID = tail.id
        else { return }

        isLoadingMore = true
        let generation = loadGeneration
        let querySnapshot = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let cursor = ClipboardHistoryStore.PageCursor(capturedAt: tail.capturedAt, id: tailID)
        let store = self.store
        let pageLimit = Self.pageSize + 1
        pageTask?.cancel()
        pageTask = Task { [weak self] in
            guard let self else { return }
            let page = await Task.detached(priority: .utility) {
                (try? store.page(
                    limit: pageLimit,
                    query: querySnapshot.isEmpty ? nil : querySnapshot,
                    before: cursor
                )) ?? []
            }.value
            guard !Task.isCancelled,
                  generation == self.loadGeneration,
                  self.query.trimmingCharacters(in: .whitespacesAndNewlines) == querySnapshot
            else {
                self.isLoadingMore = false
                return
            }
            let hasMore = page.count > Self.pageSize
            let appended = Array(page.prefix(Self.pageSize))
            let ids = appended.compactMap(\.id)
            let memberships = await Task.detached(priority: .utility) {
                store.collectionMemberships(clipboardIDs: ids)
            }.value
            guard generation == self.loadGeneration else {
                self.isLoadingMore = false
                return
            }
            self.items.append(contentsOf: appended)
            let allItems = self.items
            self.threads = await Task.detached(priority: .utility) {
                ClipboardThreadBuilder.build(from: allItems)
            }.value
            guard !Task.isCancelled, generation == self.loadGeneration else {
                self.isLoadingMore = false
                return
            }
            self.collectionMemberships.merge(memberships) { _, new in new }
            self.hasMoreItems = hasMore
            self.isLoadingMore = false
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

    func loadPasteQueue(
        _ items: [ClipboardHistoryItem],
        switchingToHistory: Bool = true
    ) {
        let unique = items.reduce(into: [ClipboardHistoryItem]()) { result, item in
            guard item.id != nil, !result.contains(where: { $0.id == item.id }) else { return }
            result.append(item)
        }
        pasteQueueItems = unique
        isContinuousSelectionEnabled = true
        autoSelectsCurrentWhenQueueEmpty = false
        pasteFeedback = unique.isEmpty ? "没有可加入队列的内容" : "已加入 \(unique.count) 项"
        if switchingToHistory { workspaceMode = .history }
    }

    func movePasteQueueItem(_ item: ClipboardHistoryItem, by delta: Int) {
        guard let source = pasteQueueItems.firstIndex(where: { $0.id == item.id }) else { return }
        let destination = min(max(0, source + delta), pasteQueueItems.count - 1)
        guard destination != source else { return }
        let moved = pasteQueueItems.remove(at: source)
        pasteQueueItems.insert(moved, at: destination)
        pasteFeedback = nil
    }

    // MARK: 线程 / 胶囊

    func createCapsuleFromQueue() {
        createCapsule(items: pasteQueueItems, proposedName: "")
    }

    func createCapsule(from thread: ClipboardThread) {
        createCapsule(items: Array(thread.items.reversed()), proposedName: thread.title)
    }

    func renameCapsule(_ name: String, snapshot: ClipboardCapsuleSnapshot) {
        guard snapshot.id >= 0 else { return }
        store.renameCapsule(name, capsuleID: snapshot.id)
        refreshCapsules()
    }

    func toggleCapsulePin(_ snapshot: ClipboardCapsuleSnapshot) {
        guard snapshot.id >= 0 else { return }
        store.setCapsulePinned(!snapshot.capsule.isPinned, capsuleID: snapshot.id)
        refreshCapsules()
    }

    func deleteCapsule(_ snapshot: ClipboardCapsuleSnapshot) {
        guard snapshot.id >= 0 else { return }
        store.deleteCapsule(snapshot.id)
        if activeCapsulePaste?.capsuleID == snapshot.id { activeCapsulePaste = nil }
        if editingCapsuleID == snapshot.id {
            editingCapsuleID = nil
            editingCapsuleName = nil
            pasteQueueItems = []
        }
        refreshCapsules()
    }

    func beginEditingCapsule(_ snapshot: ClipboardCapsuleSnapshot) {
        editingCapsuleID = snapshot.id
        editingCapsuleName = snapshot.capsule.name
        loadPasteQueue(snapshot.items, switchingToHistory: true)
        pasteFeedback = "拖动顺序可用上下箭头调整；也可以继续添加或移除卡片"
    }

    func saveCapsuleEditing() {
        guard let capsuleID = editingCapsuleID else { return }
        do {
            try store.replaceCapsuleItems(capsuleID: capsuleID, items: pasteQueueItems)
            editingCapsuleID = nil
            editingCapsuleName = nil
            pasteQueueItems = []
            autoSelectsCurrentWhenQueueEmpty = false
            pasteFeedback = "胶囊顺序已保存"
            refreshCapsules(selectMode: true)
        } catch {
            pasteFeedback = "胶囊至少需要保留一项内容"
        }
    }

    func cancelCapsuleEditing() {
        editingCapsuleID = nil
        editingCapsuleName = nil
        clearPasteQueue()
        workspaceMode = .capsules
    }

    /// 同类型胶囊一次粘贴；混合类型自动进入安全的逐项粘贴，不合成含糊的 pasteboard。
    func pasteCapsule(_ snapshot: ClipboardCapsuleSnapshot) {
        guard !snapshot.items.isEmpty else {
            pasteFeedback = "这个胶囊已经没有可用内容"
            return
        }
        let kinds = Set(snapshot.items.map(\.kind))
        if kinds.count > 1 {
            activeCapsulePaste = ClipboardCapsulePasteProgress(
                capsuleID: snapshot.id,
                name: snapshot.capsule.name,
                items: snapshot.items,
                nextIndex: 0
            )
            continueCapsulePaste()
            return
        }

        store.markCapsuleUsed(snapshot.id)
        if snapshot.items[0].kind == .text {
            let texts = snapshot.items.compactMap { store.content(of: $0).text }
            guard texts.count == snapshot.items.count else {
                pasteFeedback = "胶囊中的部分文字已不可用"
                return
            }
            finishPaste(
                items: snapshot.items,
                didCopy: Clipboard.copy(text: texts.joined(separator: snapshot.capsule.separator.value))
            )
        } else {
            loadPasteQueue(snapshot.items, switchingToHistory: false)
            pasteSelected()
        }
    }

    func continueCapsulePaste() {
        guard var progress = activeCapsulePaste,
              progress.items.indices.contains(progress.nextIndex)
        else {
            activeCapsulePaste = nil
            return
        }
        let item = progress.items[progress.nextIndex]
        if progress.nextIndex == 0 { store.markCapsuleUsed(progress.capsuleID) }
        progress.nextIndex += 1
        activeCapsulePaste = progress.nextIndex < progress.items.count ? progress : nil
        paste(item)
    }

    func cancelCapsulePaste() {
        activeCapsulePaste = nil
        pasteFeedback = nil
    }

    private func createCapsule(items: [ClipboardHistoryItem], proposedName: String) {
        guard !items.isEmpty else {
            pasteFeedback = "请先选择要保存的卡片"
            return
        }
        let store = self.store
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Result { try store.createCapsule(name: proposedName, items: items) }
            }.value
            guard let self else { return }
            switch result {
            case .success:
                self.pasteFeedback = "已保存为上下文胶囊"
                self.refreshCapsules(selectMode: true)
            case .failure:
                self.pasteFeedback = "无法保存胶囊"
            }
        }
    }

    private func refreshCapsules(selectMode: Bool = false) {
        let store = self.store
        Task { [weak self] in
            let snapshots = await Task.detached(priority: .utility) {
                (try? store.capsuleSnapshots()) ?? []
            }.value
            guard let self else { return }
            self.capsules = snapshots
            if selectMode { self.workspaceMode = .capsules }
        }
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
        NSLog(
            "[Index][ClipboardPaste] selected count=%d visible=%d index=%d",
            selectedItems.count,
            filteredItems.count,
            selectedIndex
        )
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
            let urls = selectedItems.compactMap { store.content(of: $0).assetURL }
            guard urls.count == selectedItems.count else {
                pasteFeedback = "部分图片文件已不可用"
                return
            }
            prepareImagePaste(items: selectedItems, urls: urls)
            return

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
        finishPaste(items: selectedItems, didCopy: didCopy)
    }

    /// Paste 的 Shift+Enter 语义：无论来源中以后是否保留富文本表示，
    /// 都只向系统剪贴板写 public.utf8-plain-text 再执行一次粘贴。
    func pasteSelectedAsPlainText() {
        pasteAsPlainText(pasteQueueItems)
    }

    nonisolated static func joinedTexts(_ texts: [String]) -> String {
        texts.joined(separator: "\n")
    }

    /// 鼠标双击直接粘贴命中的记录，不能再通过可能正在变化的 selectedIndex 回查。
    func paste(_ item: ClipboardHistoryItem) {
        if item.kind == .image {
            guard let url = store.content(of: item).assetURL else {
                pasteFeedback = "这条记录的内容已不可用"
                return
            }
            prepareImagePaste(items: [item], urls: [url])
            return
        }
        guard copyBack(item) else {
            pasteFeedback = "这条记录的内容已不可用"
            return
        }
        pasteFeedback = nil
        ClipboardHistoryCoordinator.shared.performPaste()
    }

    func pasteAsPlainText(_ item: ClipboardHistoryItem) {
        pasteAsPlainText([item])
    }

    private func pasteAsPlainText(_ items: [ClipboardHistoryItem]) {
        guard !items.isEmpty else {
            pasteFeedback = "请先选择要粘贴的文字卡片"
            return
        }
        guard items.allSatisfy({ $0.kind == .text }) else {
            pasteFeedback = "只有文字卡片可以按纯文本粘贴"
            return
        }
        let texts = items.compactMap { store.content(of: $0).text }
        guard texts.count == items.count else {
            pasteFeedback = "部分文字内容已不可用"
            return
        }
        finishPaste(
            items: items,
            didCopy: Clipboard.copy(text: Self.joinedTexts(texts))
        )
    }

    /// 图片历史本来就是 PNG 文件。文件读取移到后台，主线程只负责一次
    /// NSPasteboard 写入，避免双击/连续粘贴大图时解码再编码造成选中动画卡顿。
    private func prepareImagePaste(items: [ClipboardHistoryItem], urls: [URL]) {
        pastePreparationTask?.cancel()
        pasteFeedback = "正在准备图片…"
        pastePreparationTask = Task { [weak self] in
            let dataItems = await Task.detached(priority: .userInitiated) {
                var values: [Data] = []
                values.reserveCapacity(urls.count)
                for url in urls {
                    guard !Task.isCancelled,
                          let data = try? Data(contentsOf: url, options: .mappedIfSafe)
                    else { return [Data]() }
                    values.append(data)
                }
                return values
            }.value
            guard let self, !Task.isCancelled else { return }
            guard dataItems.count == items.count else {
                self.pasteFeedback = "部分图片文件已不可用"
                return
            }
            self.finishPaste(items: items, didCopy: Clipboard.copy(pngDataItems: dataItems))
        }
    }

    private func finishPaste(items: [ClipboardHistoryItem], didCopy: Bool) {
        NSLog(
            "[Index][ClipboardPaste] pasteboard write=%d count=%d kind=%@",
            didCopy ? 1 : 0,
            items.count,
            items.first.map { String(describing: $0.kind) } ?? "none"
        )
        guard didCopy else {
            pasteFeedback = "无法写入系统剪贴板"
            return
        }
        let store = self.store
        Task.detached(priority: .utility) { store.markUsed(items) }
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

    func copySelected() {
        let visible = filteredItems
        guard visible.indices.contains(selectedIndex) else {
            pasteFeedback = "请先选择要复制的卡片"
            return
        }
        pasteFeedback = copyBack(visible[selectedIndex]) ? nil : "这条记录的内容已不可用"
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
            guard let url = content.assetURL,
                  let data = try? Data(contentsOf: url, options: .mappedIfSafe)
            else {
                return false
            }
            didCopy = Clipboard.copy(pngData: data)
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

// MARK: - 页面会话

/// 剪贴板页面自己的单选状态。它独立于 GallerySelection，也不与浮动面板共享。
@MainActor
final class ClipboardSelection: ObservableObject {
    /// 兼容旧调用点；新的页面应从 ClipboardPageSession 取得 selection。
    static let shared = ClipboardSelection()

    @Published var selectedID: Int64?

    init(selectedID: Int64? = nil) {
        self.selectedID = selectedID
    }

    func select(_ id: Int64?) {
        selectedID = (selectedID == id) ? nil : id
    }

    func clear() {
        selectedID = nil
    }

    func clearIf(_ id: Int64?) {
        if selectedID == id { selectedID = nil }
    }
}

/// 一个剪贴板页面的完整状态边界。
///
/// 主 Clipboard Tab 使用 ViewModel 的 filteredItems；收藏和专题集页面则传入自己的
/// scopedItems。Inspector 永远从同一个 session 解析选中项，不再回头读取另一个 Tab。
/// 浮动剪贴板面板继续自己创建 ClipboardHistoryViewModel，不使用此会话。
@MainActor
final class ClipboardPageSession: ObservableObject {
    static let shared = ClipboardPageSession(selection: .shared)

    let viewModel: ClipboardHistoryViewModel
    let selection: ClipboardSelection

    /// nil 表示使用 viewModel.filteredItems；非 nil 表示页面拥有显式条目快照。
    @Published private(set) var scopedItems: [ClipboardHistoryItem]?

    init(
        store: ClipboardHistoryStore = .shared,
        viewModel: ClipboardHistoryViewModel? = nil,
        selection: ClipboardSelection? = nil,
        scopedItems: [ClipboardHistoryItem]? = nil
    ) {
        self.viewModel = viewModel ?? ClipboardHistoryViewModel(store: store)
        self.selection = selection ?? ClipboardSelection()
        self.scopedItems = scopedItems
        reconcileSelection()
    }

    var visibleItems: [ClipboardHistoryItem] {
        scopedItems ?? viewModel.filteredItems
    }

    var selectedItem: ClipboardHistoryItem? {
        guard let selectedID = selection.selectedID else { return nil }
        return visibleItems.first { $0.id == selectedID }
    }

    func setScopedItems(_ items: [ClipboardHistoryItem]?) {
        guard scopedItems != items else { return }
        scopedItems = items
        reconcileSelection()
    }

    func updateScopedItem(_ item: ClipboardHistoryItem) {
        guard var scopedItems,
              let index = scopedItems.firstIndex(where: { $0.id == item.id })
        else { return }
        scopedItems[index] = item
        self.scopedItems = scopedItems
    }

    func removeScopedItem(_ item: ClipboardHistoryItem) {
        if var scopedItems {
            scopedItems.removeAll { $0.id == item.id }
            self.scopedItems = scopedItems
        }
        selection.clearIf(item.id)
    }

    private func reconcileSelection() {
        guard let selectedID = selection.selectedID,
              !visibleItems.contains(where: { $0.id == selectedID })
        else { return }
        selection.clear()
    }
}

/// 源码兼容名；新的调用点使用 ClipboardPageSession。
typealias ClipboardTabSession = ClipboardPageSession
