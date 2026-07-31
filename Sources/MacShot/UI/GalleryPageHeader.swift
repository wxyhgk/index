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

struct GalleryPageHeader: View {

    @ObservedObject private var store = ShotStore.shared

    // 这里从前还存着 apps / categories / tags 三份聚合查询，只为填四个下拉胶囊的菜单。
    // 胶囊删掉之后它们一并消失 —— 顺带省掉了每次 store 变更都要跑的三条 GROUP BY
    // （侧边栏本来就在算同样的三份，那是第二次重复）。

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.s3) {
            Text(title)
                .font(.largeTitle.weight(.bold))
                .lineLimit(1)
            clearFilterButton
            Spacer(minLength: DS.s2)
            // displayShots 是内存里的数组，count 是 O(1)，可以留在 body 里。
            Text("\(store.displayShots.count) 个项目")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .fixedSize()
        }
    }

    // MARK: - 大标题

    /// 标题 = 当前筛选的名字。搜索不参与标题（搜索是在筛选结果里再缩小一次，
    /// 把标题换成关键词会让人以为筛选被清掉了）；结果条数由右侧那行小字反映。
    private var title: String {
        switch store.filter {
        case .all:                  return "全部截图"
        case .favorites:            return "收藏"
        case .untagged:             return "未加标签"
        case .annotated:            return "已标注"
        case .category(let name):   return name
        case .tag(let name):        return name
        }
    }

    // MARK: - 清除筛选

    /// 正在筛选时，标题旁边一个「✕」。大标题已经写着筛的是什么，
    /// 所以这里不再重复那个名字，只提供退出口。
    @ViewBuilder
    private var clearFilterButton: some View {
        if store.filter != .all {
            Button {
                store.filter = .all
                store.reload()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("清除筛选，回到全部截图")
            .accessibilityLabel("清除筛选")
        }
    }

}

// MARK: - 筛选维度取值

/// 两个「带参数」的筛选各自的值。写成计算属性而不是在视图里 switch：
/// 标题、命中判定都要问同一个问题，问法只该有一种。
extension ShotStore.GalleryFilter {

    var categoryName: String? {
        if case .category(let name) = self { return name }
        return nil
    }

    var tagName: String? {
        if case .tag(let name) = self { return name }
        return nil
    }
}
