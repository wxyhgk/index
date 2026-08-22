import Combine
import Foundation

/// 图库窗口的查询与搜索状态。
///
/// `ShotStore` 只负责持久化数据和当前列表缓存；搜索词、筛选、语义模式及异步结果
/// 都属于图库界面会话，由这里统一持有。固定 destination、顶栏、网格、快捷键和
/// URL 自动化必须通过同一个实例读写，避免出现两份筛选真相。
@MainActor
final class GalleryViewModel: ObservableObject {

    static let shared = GalleryViewModel(store: .shared)

    /// 工厂：shared store 返回共享实例，否则新建。
    /// 收敛 8 处 `store === ShotStore.shared ? .shared : GalleryViewModel(store:)` 重复判断。
    static func resolve(for store: ShotStore) -> GalleryViewModel {
        store === ShotStore.shared ? .shared : GalleryViewModel(store: store)
    }

    /// shared store 返回共享实例的 displayShots，否则 nil（调用方 fallback 到 store.shots）。
    static func displayShots(for store: ShotReading) -> [Shot]? {
        guard let concrete = store as? ShotStore, concrete === ShotStore.shared else { return nil }
        return shared.displayShots
    }

    /// shared store 走共享实例的 allMatchingIDs（含当前搜索词/筛选），否则走 store 全量查询。
    static func allMatchingIDs(for store: ShotReading) async -> [Int64] {
        guard let concrete = store as? ShotStore, concrete === ShotStore.shared else {
            return await store.allMatchingIDs(query: "", filter: .all)
        }
        return await shared.allMatchingIDs()
    }

    let store: ShotStore

    @Published var searchText = ""
    @Published var filter: ShotFilter = .all
    @Published var semanticMode = false
    @Published private(set) var semanticResults: [Shot]?
    @Published private(set) var isSemanticSearching = false

    private var semanticSearchGeneration = 0
    private var exactSearchGeneration = 0
    private var exactSearchTask: Task<Void, Never>?

    init(store: ShotStore) {
        self.store = store
    }

    var shots: [Shot] { store.shots }
    var displayShots: [Shot] {
        semanticMode ? (semanticResults ?? store.shots) : store.shots
    }

    func reload() {
        store.reload(query: searchText, filter: filter)
    }

    /// 新建一个 Markdown 卡片。
    func createMarkdownCard() {
        let defaultSource = """
        # 新建笔记

        在这里输入内容…
        """
        do {
            let shot = try store.createMarkdownShot(title: "新建笔记", source: defaultSource)
            store.reload(query: searchText, filter: filter)
            _ = shot
        } catch {
            NSLog("[Index] 新建 Markdown 卡片失败: \(error)")
        }
    }

    func reloadInBackground() async {
        await store.reloadInBackground(query: searchText, filter: filter)
    }

    /// 精确搜索只在输入停顿后执行。每轮捕获查询快照，旧任务即使迟到也不能覆盖新条件。
    func scheduleExactSearch(debounce: Duration = .milliseconds(200)) {
        exactSearchGeneration += 1
        let generation = exactSearchGeneration
        let query = searchText
        let activeFilter = filter
        exactSearchTask?.cancel()
        exactSearchTask = Task { [weak self] in
            do {
                try await Task.sleep(for: debounce)
            } catch {
                return
            }
            guard let self,
                  generation == self.exactSearchGeneration,
                  !self.semanticMode,
                  self.searchText == query,
                  self.filter == activeFilter
            else { return }
            await self.store.reloadInBackground(query: query, filter: activeFilter)
            guard generation == self.exactSearchGeneration else { return }
            GalleryPerformance.searchFinished(generation: generation, count: self.store.shots.count)
        }
    }

    func cancelPendingExactSearch() {
        exactSearchGeneration += 1
        exactSearchTask?.cancel()
        exactSearchTask = nil
    }

    func loadNextPage() async {
        guard !semanticMode || semanticResults == nil else { return }
        await store.loadNextPage()
    }

    func allMatchingIDs() async -> [Int64] {
        await store.allMatchingIDs(query: searchText, filter: filter)
    }

    /// 只接受仍属于当前查询会话的结果。清空、切换模式或 destination 都会使旧请求失效。
    func runSemanticSearch() async {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            clearSemanticResults()
            return
        }
        let activeFilter = filter
        semanticSearchGeneration += 1
        let generation = semanticSearchGeneration
        isSemanticSearching = true
        let results = await store.semanticSearch(query: query, filter: activeFilter)
        guard generation == semanticSearchGeneration else { return }
        isSemanticSearching = false
        guard semanticMode,
              searchText.trimmingCharacters(in: .whitespacesAndNewlines) == query,
              filter == activeFilter
        else { return }
        semanticResults = results
    }

    func clearSemanticResults() {
        semanticSearchGeneration += 1
        semanticResults = nil
        isSemanticSearching = false
    }

    func reset(to filter: ShotFilter = .all) {
        cancelPendingExactSearch()
        searchText = ""
        clearSemanticResults()
        self.filter = filter
        reload()
    }

    func renameTag(_ old: String, to new: String) {
        let name = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != old else { return }
        store.renameTag(old, to: name)
        if filter == .tag(old) { filter = .tag(name) }
        reload()
    }

    func deleteTag(_ tag: String) {
        store.deleteTag(tag)
        if filter == .tag(tag) { filter = .all }
        reload()
    }

    func deleteCollection(id: Int64) {
        store.deleteCollection(id: id)
        if filter == .collection(id) { filter = .all }
        reload()
    }
}

/// `GalleryGrid` 只关心会改变可见图片集合的语义模式与语义结果。
///
/// 网格若直接 `@ObservedObject` 整个 `GalleryViewModel`，搜索框每敲一个字符、搜索中的
/// spinner 每翻一次状态，都会让几百张卡片整棵重算，尽管精确搜索尚在 debounce。
/// 这个投影只转发真正改变网格内容的两条信号；顶栏仍观察完整 ViewModel。
@MainActor
final class GalleryGridPresentation: ObservableObject {
    let objectWillChange = ObservableObjectPublisher()

    private(set) var semanticMode: Bool
    private(set) var semanticResults: [Shot]?
    private(set) var revision = 0
    private var cancellables: Set<AnyCancellable> = []

    init(viewModel: GalleryViewModel) {
        semanticMode = viewModel.semanticMode
        semanticResults = viewModel.semanticResults

        viewModel.$semanticMode
            .dropFirst()
            .sink { [weak self] value in
                guard let self else { return }
                self.objectWillChange.send()
                self.semanticMode = value
                self.revision &+= 1
            }
            .store(in: &cancellables)

        viewModel.$semanticResults
            .dropFirst()
            .sink { [weak self] results in
                guard let self else { return }
                self.objectWillChange.send()
                self.semanticResults = results
                self.revision &+= 1
            }
            .store(in: &cancellables)
    }

    func displayShots(fallback: [Shot]) -> [Shot] {
        semanticMode ? (semanticResults ?? fallback) : fallback
    }
}
