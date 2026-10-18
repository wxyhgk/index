import AppKit
import Combine
import UniformTypeIdentifiers

// ============================================================
// MARK: - 剪贴板历史视图模型：数据加载 + 分页 + 搜索防抖
// ============================================================

extension ClipboardHistoryViewModel {
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
        let collectionRepo = shotStore.collectionRepository
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
            async let totalCountValue: Int = Task.detached(priority: .utility) {
                store.totalCount()
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
            self.totalCount = await totalCountValue
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

    func setTypeFilter(_ kind: ClipboardHistoryKind?, tag: String? = nil) {
        typeFilter = kind
        tagFilter = tag
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

}
