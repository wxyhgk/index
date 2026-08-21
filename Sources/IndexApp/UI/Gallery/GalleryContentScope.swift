import Foundation

/// 图库网格的内容范围。顶层 destination 和普通数据筛选是两种状态：
/// `.library` 允许用户清掉当前筛选；`.recordings` 是入口本身的固定边界，
/// 清搜索只能回到「全部录屏」，不能越界回到整个图库。
enum GalleryContentScope: Equatable {
    case library
    case recordings
    case favorites
    case collection(id: Int64, title: String)

    var fixedFilter: ShotFilter? {
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
        filter: ShotFilter,
        hasSemanticResults: Bool
    ) -> Bool {
        !searchText.isEmpty
            || hasSemanticResults
            || (fixedFilter == nil && filter != .all)
    }

    @MainActor
    func activate(in viewModel: GalleryViewModel) {
        let targetFilter = fixedFilter ?? .all
        // 短路：filter 和 searchText 都已匹配时不跑 reload，
        // 避免 tab 切换时重复 DB 查询（条件渲染下每次切换都触发 activate）。
        if viewModel.filter == targetFilter && viewModel.searchText.isEmpty {
            return
        }
        // destination 切换不继承上一入口的查询结果；否则语义结果会短暂越过固定范围。
        viewModel.searchText = ""
        viewModel.clearSemanticResults()
        viewModel.filter = targetFilter
        // 异步重建查询：同步 reload 用 GRDB `.immediate` scheduling，首次查询跑在
        // 主线程渲染帧内，是 tab 切换视觉延迟的来源。异步版把 DB 查询移出渲染帧。
        // 捕获当前状态，避免 Task 执行时 viewModel 已被后续操作修改。
        let query = viewModel.searchText
        let filter = viewModel.filter
        Task { await viewModel.store.reloadInBackground(query: query, filter: filter) }
    }

    @MainActor
    func deactivate(in viewModel: GalleryViewModel) {
        guard fixedFilter != nil else { return }
        // 清状态 + 异步 reload：切走的 tab 不再可见，但 store.shots 要更新为 .all，
        // 这样切回图库 tab 时数据已就绪。异步 reload 不阻塞渲染帧；
        // 若紧接着的 activate 也 reload，generation 防迟到保证只有最新的生效。
        viewModel.cancelPendingExactSearch()
        viewModel.searchText = ""
        viewModel.clearSemanticResults()
        viewModel.filter = .all
        Task { await viewModel.store.reloadInBackground(query: "", filter: .all) }
    }

    @MainActor
    func clearTransientState(in viewModel: GalleryViewModel) {
        viewModel.reset(to: fixedFilter ?? .all)
    }
}
