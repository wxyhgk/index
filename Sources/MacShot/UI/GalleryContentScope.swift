import Foundation

/// 图库网格的内容范围。顶层 destination 和普通数据筛选是两种状态：
/// `.library` 允许用户清掉当前筛选；`.recordings` 是入口本身的固定边界，
/// 清搜索只能回到「全部录屏」，不能越界回到整个图库。
enum GalleryContentScope: Equatable {
    case library
    case recordings
    case favorites
    case collection(id: Int64, title: String)

    var fixedFilter: ShotStore.GalleryFilter? {
        switch self {
        case .library: return nil
        case .recordings: return .recordings
        case .favorites: return .favorites
        case .collection(let id, _): return .collection(id)
        }
    }

    var fixedTitle: String? {
        switch self {
        case .library: return nil
        case .recordings: return "录屏"
        case .favorites: return "快速收藏"
        case .collection(_, let title): return title
        }
    }

    var emptyTitle: String? {
        switch self {
        case .library: return nil
        case .recordings: return "还没有录屏"
        case .favorites: return "还没有快速收藏"
        case .collection: return "这个专题集还是空的"
        }
    }

    var emptyDescription: String? {
        switch self {
        case .library: return nil
        case .recordings: return "完成录屏后会显示在这里"
        case .favorites: return "在图库里点亮星标，图片会出现在这里"
        case .collection: return "从图片右键菜单或详情栏把图片加入这里"
        }
    }

    var emptyIcon: String? {
        switch self {
        case .library: return nil
        case .recordings: return "play.rectangle"
        case .favorites: return "star"
        case .collection: return "rectangle.stack.badge.plus"
        }
    }

    var showsStartCaptureAction: Bool { fixedFilter == nil }

    func hasClearableState(
        searchText: String,
        filter: ShotStore.GalleryFilter,
        hasSemanticResults: Bool
    ) -> Bool {
        !searchText.isEmpty
            || hasSemanticResults
            || (fixedFilter == nil && filter != .all)
    }

    @MainActor
    func activate(in store: ShotStore) {
        // destination 切换不继承上一入口的查询结果；否则语义结果会短暂越过固定范围。
        store.searchText = ""
        store.clearSemanticResults()
        if let fixedFilter { store.filter = fixedFilter }
        store.reload()
    }

    @MainActor
    func deactivate(in store: ShotStore) {
        guard fixedFilter != nil else { return }
        store.searchText = ""
        store.clearSemanticResults()
        store.filter = .all
        store.reload()
    }

    @MainActor
    func clearTransientState(in store: ShotStore) {
        store.searchText = ""
        store.clearSemanticResults()
        store.filter = fixedFilter ?? .all
        store.reload()
    }
}
