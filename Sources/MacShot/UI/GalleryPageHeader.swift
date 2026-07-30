import SwiftUI

// MARK: - 内容区页头
//
// 设计稿 §4 的前两项：大标题（随当前筛选变化）+ 右侧「N 个项目」，
// 下面一行筛选胶囊（最近 ▾ / 应用 ▾ / 类型 ▾ / 标签 ▾）。
//
// 胶囊和侧边栏读写的是**同一个** `store.filter`：这边选「浏览器」，侧边栏的
// 分类行同时高亮；侧边栏点「收藏」，这边的大标题跟着变成「收藏」。
// 两边互相反映不是 bug —— 那本来就是一份状态的两个入口。

struct GalleryPageHeader: View {

    @ObservedObject private var store = ShotStore.shared

    // 三份聚合查询的结果。**绝不放进 body** —— 那是每帧三条 GROUP BY。
    // 刷新时机与侧边栏完全一致（见 refresh()）。
    @State private var apps: [(name: String, bundleID: String?, count: Int)] = []
    @State private var categories: [(name: String, count: Int)] = []
    @State private var tags: [(name: String, count: Int)] = []

    var body: some View {
        VStack(alignment: .leading, spacing: DS.s3) {
            HStack(alignment: .firstTextBaseline, spacing: DS.s3) {
                Text(title)
                    .font(.largeTitle.weight(.bold))
                    .lineLimit(1)
                Spacer(minLength: DS.s2)
                // displayShots 是内存里的数组，count 是 O(1)，可以留在 body 里。
                Text("\(store.displayShots.count) 个项目")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .fixedSize()
            }

            chipRow
        }
        // 聚合是几条小查询，跟着 store 的每一次变更重查一遍 ——
        // 通知发在写库**之后**，这里直接读库拿到的已是新值（同 GallerySidebar.refresh）。
        .task { refresh() }
        .onReceive(store.objectWillChange) { _ in refresh() }
    }

    // MARK: - 大标题

    /// 标题 = 当前筛选的名字。搜索不参与标题（搜索是在筛选结果里再缩小一次，
    /// 把标题换成关键词会让人以为筛选被清掉了）；结果条数由右侧那行小字反映。
    private var title: String {
        switch store.filter {
        case .all:                  return "全部截图"
        case .favorites:            return "收藏"
        case .today:                return "今天"
        case .thisWeek:             return "本周"
        case .untagged:             return "未加标签"
        case .annotated:            return "已标注"
        case .category(let name):   return name
        case .app(let name):        return name
        case .tag(let name):        return name
        }
    }

    // MARK: - 筛选胶囊行

    private var chipRow: some View {
        HStack(spacing: DS.s2) {
            recentChip
            appChip
            categoryChip
            tagChip
            Spacer(minLength: 0)
        }
    }

    /// 「最近」= 时间维度，对应 `.today` / `.thisWeek` 两个筛选。
    private var recentChip: some View {
        chip(dimension: "最近", value: timeValue) {
            Button("全部时间") { clearDimension(isTime) }
                .disabled(timeValue == nil)
            Divider()
            Button("今天") { select(.today) }
            Button("本周") { select(.thisWeek) }
        }
    }

    private var appChip: some View {
        chip(dimension: "应用", value: store.filter.appName) {
            Button("全部应用") { clearDimension(isApp) }
                .disabled(store.filter.appName == nil)
            if !apps.isEmpty { Divider() }
            ForEach(apps, id: \.name) { app in
                Button("\(app.name)（\(app.count)）") { select(.app(app.name)) }
            }
        }
    }

    private var categoryChip: some View {
        chip(dimension: "类型", value: store.filter.categoryName) {
            Button("全部类型") { clearDimension(isCategory) }
                .disabled(store.filter.categoryName == nil)
            if !categories.isEmpty { Divider() }
            ForEach(categories, id: \.name) { category in
                Button("\(category.name)（\(category.count)）") { select(.category(category.name)) }
            }
        }
    }

    private var tagChip: some View {
        chip(dimension: "标签", value: store.filter.tagName) {
            Button("全部标签") { clearDimension(isTag) }
                .disabled(store.filter.tagName == nil)
            if !tags.isEmpty { Divider() }
            ForEach(tags, id: \.name) { tag in
                Button("\(tag.name)（\(tag.count)）") { select(.tag(tag.name)) }
            }
        }
    }

    /// 一个下拉胶囊。未选中显示维度名（「应用」），选中显示所选的值（「Chrome」）
    /// 并点亮 —— 一行胶囊扫过去就知道现在筛的是什么，不需要再展开确认。
    private func chip(
        dimension: String,
        value: String?,
        @ViewBuilder menu: () -> some View
    ) -> some View {
        Menu {
            menu()
        } label: {
            HStack(spacing: DS.s1) {
                Text(value ?? dimension)
                    .font(.system(size: 13))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .opacity(0.7)
            }
        }
        .menuStyle(.button)
        .buttonStyle(FilterChipButtonStyle(isActive: value != nil))
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(value == nil ? "按\(dimension)筛选" : "\(dimension)：\(value!)")
    }

    // MARK: - 筛选读写
    //
    // `GalleryFilter` 是单选的枚举，胶囊行只是它的四个「维度视图」：
    // 选任何一项都替换掉整个筛选，「全部 X」只在当前筛的正是这个维度时才有事做
    // （否则会把别人维度的选择顺手清掉，那是用户没要求的）。

    private func select(_ filter: ShotStore.GalleryFilter) {
        store.filter = filter
        store.reload()
    }

    private func clearDimension(_ belongs: (ShotStore.GalleryFilter) -> Bool) {
        guard belongs(store.filter) else { return }
        store.filter = .all
        store.reload()
    }

    private var timeValue: String? {
        switch store.filter {
        case .today:    return "今天"
        case .thisWeek: return "本周"
        default:        return nil
        }
    }

    private func isTime(_ filter: ShotStore.GalleryFilter) -> Bool {
        filter == .today || filter == .thisWeek
    }

    private func isApp(_ filter: ShotStore.GalleryFilter) -> Bool {
        filter.appName != nil
    }

    private func isCategory(_ filter: ShotStore.GalleryFilter) -> Bool {
        filter.categoryName != nil
    }

    private func isTag(_ filter: ShotStore.GalleryFilter) -> Bool {
        filter.tagName != nil
    }

    // MARK: - 数据

    private func refresh() {
        apps = store.apps()
        categories = store.categories()
        tags = store.allTags()
    }
}

// MARK: - 胶囊按钮样式

/// 筛选胶囊：全圆角、13pt、深色底；选中时染 accent（不是填实心 ——
/// 胶囊里写的是用户选的**值**，实心底会把它压成不可读的白字块）。
///
/// `@State` 不能写在 ButtonStyle 上（不是 View，没有视图身份），
/// 悬停态实现在嵌套的 `Surface` 里 —— 同 ShellIconButtonStyle。
struct FilterChipButtonStyle: ButtonStyle {

    var isActive: Bool

    func makeBody(configuration: Configuration) -> some View {
        Surface(configuration: configuration, isActive: isActive)
    }

    private struct Surface: View {

        let configuration: ButtonStyleConfiguration
        let isActive: Bool

        @Environment(\.colorScheme) private var scheme
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var hovering = false

        var body: some View {
            configuration.label
                .foregroundStyle(isActive ? Color.accentColor : Color.primary)
                .padding(.horizontal, DS.s3)
                .frame(height: DS.Shell.chipHeight)
                .background(fill, in: Capsule())
                .overlay {
                    if isActive {
                        Capsule().strokeBorder(Color.accentColor.opacity(0.45), lineWidth: 1)
                    }
                }
                .contentShape(Capsule())
                .scaleEffect(configuration.isPressed ? DS.Lift.pressScale : 1)
                .onHover { hovering = $0 }
                .animation(DS.Motion.micro(reduced: reduceMotion), value: hovering)
                .animation(DS.Motion.micro(reduced: reduceMotion), value: configuration.isPressed)
        }

        /// 亮度阶梯那一套：深色加白、浅色加黑；选中态换成 accent 的淡染。
        private var fill: Color {
            if isActive {
                return .accentColor.opacity(hovering ? 0.26 : 0.18)
            }
            let base = scheme == .dark ? 0.07 : 0.05
            let boost = hovering ? 0.05 : 0.0
            return scheme == .dark
                ? .white.opacity(base + boost)
                : .black.opacity(base + boost)
        }
    }
}

// MARK: - 筛选维度取值

/// 三个「带参数」的筛选各自的值。写成计算属性而不是在视图里 switch 三遍：
/// 胶囊、标题、命中判定都要问同一个问题，问法只该有一种。
extension ShotStore.GalleryFilter {

    var appName: String? {
        if case .app(let name) = self { return name }
        return nil
    }

    var categoryName: String? {
        if case .category(let name) = self { return name }
        return nil
    }

    var tagName: String? {
        if case .tag(let name) = self { return name }
        return nil
    }
}
