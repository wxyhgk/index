import SwiftUI

// MARK: - 内容区页头
//
// 大标题（随当前筛选变化）+ 右侧「N 个项目」+ 当前筛选的可清除标记。
//
// **这里只显示状态，不做选择。** 曾经这一行是四个常驻下拉胶囊
// （最近 ▾ / 应用 ▾ / 类型 ▾ / 标签 ▾），而侧边栏面板里同样列着分类、标签、
// 应用、今天/本周，顶栏还有一个漏斗菜单 —— 同一个 `store.filter` 被画了三四遍，
// 屏幕上到处是重复入口，这正是「侧边栏显得杂」的根源。
//
// 收敛后的分工：**选择归侧边栏，状态归页头**。没有筛选时这一行完全不出现。

enum GalleryPageHeaderStyle {
    case standard
    case libraryPanel
}

struct GalleryPageHeader: View {

    @ObservedObject private var viewModel: GalleryViewModel
    private let scope: GalleryContentScope
    private let style: GalleryPageHeaderStyle

    init(
        store: ShotStore = .shared,
        viewModel: GalleryViewModel? = nil,
        scope: GalleryContentScope = .library,
        style: GalleryPageHeaderStyle = .standard
    ) {
        let resolvedViewModel = viewModel
            ?? .resolve(for: store)
        _viewModel = ObservedObject(wrappedValue: resolvedViewModel)
        self.scope = scope
        self.style = style
    }

    // 这里从前还存着 apps / categories / tags 三份聚合查询，只为填四个下拉胶囊的菜单。
    // 胶囊删掉之后它们一并消失 —— 顺带省掉了每次 store 变更都要跑的三条 GROUP BY
    // （侧边栏本来就在算同样的三份，那是第二次重复）。

    @ViewBuilder
    var body: some View {
        if style == .libraryPanel {
            libraryPanelHeader
        } else {
            standardHeader
        }
    }

    private var standardHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.s3) {
            Text(title)
                .font(.largeTitle.weight(.bold))
                .lineLimit(1)
            clearFilterButton
            Spacer(minLength: DS.s2)
            // displayShots 是内存里的数组，count 是 O(1)，可以留在 body 里。
            Text("\(visibleShots.count) 个项目")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .fixedSize()
        }
    }

    /// 第一版图库工作区页头：标题和数量形成一个纵向信息组，右侧只保留
    /// 当前真实存在的排序口径与语义搜索状态。它不新增另一套筛选入口。
    private var libraryPanelHeader: some View {
        HStack(alignment: .top, spacing: DS.s4) {
            VStack(alignment: .leading, spacing: DS.s1) {
                HStack(alignment: .firstTextBaseline, spacing: DS.s2) {
                    Text(title)
                        .font(.largeTitle.weight(.bold))
                        .lineLimit(1)
                    clearFilterButton
                }

                Text("\(visibleShots.count) 个项目")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Spacer(minLength: DS.s3)

            HStack(spacing: DS.s3) {
                semanticStatus
                Label("按创建时间", systemImage: "arrow.down")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .accessibilityLabel("按创建时间排序，最新在前")
            }
            .padding(.top, DS.s2)
        }
    }

    @ViewBuilder
    private var semanticStatus: some View {
        if viewModel.isSemanticSearching {
            HStack(spacing: DS.s2) {
                ProgressView().controlSize(.mini)
                // 与 GalleryFloatingToolbar 同一文案（语义搜索进行中）。
                Text("语义搜索中…")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        } else if viewModel.semanticMode, viewModel.semanticResults != nil {
            Text("语义结果 \(visibleShots.count) 项")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    // MARK: - 大标题

    /// 标题 = 当前筛选的名字。搜索不参与标题（搜索是在筛选结果里再缩小一次，
    /// 把标题换成关键词会让人以为筛选被清掉了）；结果条数由右侧那行小字反映。
    private var title: String {
        if let fixedTitle = scope.fixedTitle { return fixedTitle }
        switch viewModel.filter {
        case .all:                  return "全部项目"
        case .favorites:            return "收藏"
        case .untagged:             return "未加标签"
        case .annotated:            return "已标注"
        case .recordings:           return "录屏"
        case .category(let name):   return name
        case .tag(let name):        return name
        case .app(let identity):    return identity.name
        case .collection:           return "专题收藏"
        }
    }

    // MARK: - 清除筛选

    /// 正在筛选时，标题旁边一个「✕」。大标题已经写着筛的是什么，
    /// 所以这里不再重复那个名字，只提供退出口。
    @ViewBuilder
    private var clearFilterButton: some View {
        if scope.fixedFilter == nil, viewModel.filter != .all {
            Button {
                scope.clearTransientState(in: viewModel)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: DS.font15))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("清除筛选，回到全部项目")
            .accessibilityLabel("清除筛选")
        }
    }

    private var visibleShots: [Shot] {
        viewModel.displayShots
    }

}

// MARK: - 筛选维度取值

/// 两个「带参数」的筛选各自的值。写成计算属性而不是在视图里 switch：
/// 标题、命中判定都要问同一个问题，问法只该有一种。
extension ShotFilter {

    var categoryName: String? {
        if case .category(let name) = self { return name }
        return nil
    }

    var tagName: String? {
        if case .tag(let name) = self { return name }
        return nil
    }
}
