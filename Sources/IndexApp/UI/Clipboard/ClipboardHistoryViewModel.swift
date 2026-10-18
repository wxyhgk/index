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
    static let pageSize = 100

    /// 无界面的命令入口（收藏/搜索结果等）复用这一实例执行 store 动作。
    /// 主窗口 Tab 与浮动面板各自拥有独立实例，避免筛选、选择和窗口生命周期联动。
    static let shared = ClipboardHistoryViewModel(store: .shared)

    let store: ClipboardHistoryStore
    let shotStore = ShotStore.shared

    @Published var items: [ClipboardHistoryItem] = [] {
        didSet { recomputeFilteredItems() }
    }
    @Published var query = ""
    @Published var selectedIndex: Int = 0
    /// 搜索结果只是候选集；队列保存完整条目快照，因此选中项被搜索隐藏后
    /// 仍然可见、可移除、可粘贴，也不会因候选列表重排而改变顺序。
    @Published var pasteQueueItems: [ClipboardHistoryItem] = []
    @Published var pasteFeedback: String?
    @Published var isContinuousSelectionEnabled = false
    @Published var typeFilter: ClipboardHistoryKind? = nil {
        didSet { recomputeFilteredItems() }
    }
    /// 结构化标签过滤（"url" 匹配含 url tag 的条目，"code" 匹配 code:swift 等）。
    @Published var tagFilter: String? = nil {
        didSet { recomputeFilteredItems() }
    }
    @Published var collectionSummaries: [ShotCollectionSummary] = []
    @Published var collectionMemberships: [Int64: Set<Int64>] = [:]
    @Published var hasMoreItems = false
    @Published var isLoadingMore = false
    /// 数据库总条数（COUNT(*)），面板标题栏显示用。
    @Published var totalCount: Int = 0
    @Published var workspaceMode: ClipboardWorkspaceMode = .history
    /// 点击组卡片后聚焦显示其全部条目（非 nil 时历史模式只显示该组）。
    @Published var focusedGroup: FocusedGroup?
    @Published var threads: [ClipboardThread] = []
    @Published var capsules: [ClipboardCapsuleSnapshot] = []
    @Published var activeCapsulePaste: ClipboardCapsulePasteProgress?
    @Published var capsuleQuery = ""
    @Published var editingCapsuleID: Int64?
    @Published var editingCapsuleName: String?

    var searchTask: Task<Void, Never>?
    var refreshTask: Task<Void, Never>?
    var pageTask: Task<Void, Never>?
    var pastePreparationTask: Task<Void, Never>?
    var loadGeneration = 0
    var autoSelectsCurrentWhenQueueEmpty = true
    init(store: ClipboardHistoryStore) {
        self.store = store
    }

    /// 缓存：items/typeFilter/tagFilter 任一变化时重算一次，body 内 O(1) 读取。
    /// 替代原来的计算属性（每 body 被 4 处访问 × 100 条 hasTag JSON 解析 = 400 次/tick）。
    @Published private(set) var filteredItems: [ClipboardHistoryItem] = []

    private func recomputeFilteredItems() {
        var result = items
        if let kind = typeFilter {
            result = result.filter { $0.kind == kind }
        }
        if let tag = tagFilter {
            result = result.filter { $0.hasTag(tag) }
        }
        filteredItems = result
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

    /// 按 AI 推断的 sessionLabel 分组（时间倒序，最新 session 在前）。
    var sessionGroups: [ClipboardSessionGroup] {
        let withSession = items.filter { $0.sessionLabel?.isEmpty == false }
        let grouped = Dictionary(grouping: withSession) { $0.sessionLabel! }
        return grouped
            .map { label, items in
                let sorted = items.sorted { $0.capturedAt > $1.capturedAt }
                return ClipboardSessionGroup(id: label, label: label, items: sorted)
            }
            .sorted { $0.latestAt > $1.latestAt }
    }

    func selectionOrdinal(for item: ClipboardHistoryItem) -> Int? {
        guard let id = item.id,
              let index = pasteQueueItems.firstIndex(where: { $0.id == id })
        else { return nil }
        return index + 1
    }
}
