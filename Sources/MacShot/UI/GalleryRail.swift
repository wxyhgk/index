import SwiftUI
import AppKit

// MARK: - 左侧图标轨 + 可折叠标签面板（外壳的左侧一整块）
//
// 设计稿 §2/§3 把原来那条 232 宽的侧边栏拆成了两块：
//
//   · **图标轨**（本文件的 `GalleryRail`）：56 宽的竖向浮动圆角卡片，一列 44×44
//     圆角方图标，每个图标下方一个小号计数。内容 = 资料库的两个落点（全部 / 收藏）
//     + **截图数最多的几个分类**，最底部固定一个设置齿轮。永远可见。
//   · **标签面板**（`GallerySidebar`，在 GallerySidebar.swift）：168 宽，
//     四组筛选的**全量**带文字列表。它是图标轨的展开态，可折叠、状态跨启动记住。
//
// 怎么分的，理由只有一条：**轨是「常去的地方」，面板是「全部的地方」。**
//   · 轨上只有 5~6 个格子，放得下的只有「全部 / 收藏」这两个默认落点和最热的
//     几个分类（按数量取前 N，不是硬编码分类名 —— 分类表是数据算出来的）；
//   · 标签、今天 / 本周 / 未加标签 / 已标注、完整应用列表都放不下，全在面板里；
//   · 投放目标（拖一批卡片过来打标签 / 收藏）两边都要能用：收藏行在轨上就是
//     投放目标，标签行在面板里；面板收起时，拖着截图**悬停在轨顶的展开按钮上**
//     它会自己弹开（macOS 弹簧加载文件夹的老规矩），所以「投放目标不可达」这种
//     死角不存在。
//
// 共用件放在这里（轨和面板都要）：尺寸、计数数据源、分类图标表、筛选落地函数。
// 投放目标本身（`ShotDropTarget` / `GalleryDropActions`）留在 GallerySidebar.swift ——
// 那串「为什么只认 ShotIDPayload」的事故记录跟着代码走，不搬。

// ============================================================
// MARK: - 尺寸
// ============================================================

/// 左侧两块的尺寸。**没有进 `DesignTokens.swift`** —— 那个文件这一轮不许改，
/// 缺的档（56 / 44 / 36 行高 / 20 的圆角）已写进交付报告。等它补齐 `DS.Shell.*`，
/// 这个 enum 应当整个删掉。
enum RailMetrics {

    /// 图标轨宽（设计稿 56）。
    static let railWidth: CGFloat = 56
    /// 轨上图标按钮的边长（设计稿 44×44）。
    static let iconSide: CGFloat = 44
    /// 轨与标签面板之间的缝。
    ///
    /// 必须是 8：`DS.Shell.sidebarWidth`(232) 的注释写明它 = 56 + 缝 + 168，
    /// 下面的 `panelWidth` 是从那个 token 反推的 —— 缝改了宽度自己会跟着对。
    static let gap: CGFloat = DS.s2
    /// 标签面板宽（设计稿 168）。从 `DS.Shell.sidebarWidth` 反推而不是另写一个
    /// 字面量：左侧总宽只能有一份真相，不然展开态会比外壳预算宽出几个点。
    static let panelWidth: CGFloat = DS.Shell.sidebarWidth - railWidth - gap
    /// 标签面板的行高（设计稿约 40）。
    /// 拆成「36 的行 + 4 的行距」= 40 的节奏：选中态那块浅色圆底包住 36 就够，
    /// 整整 40 高的实心块在 168 宽的面板里会显得笨重。
    static let rowHeight: CGFloat = 36
    static let rowSpacing: CGFloat = DS.s1
    /// 轨上「高频分类」最多几个。
    ///
    /// 3 不是随手取的：最小窗高 600 减掉顶栏 72 与上下留白之后，轨里能排的
    /// 格子数就是 8（展开按钮 + 全部 + 收藏 + 3 个分类 + 齿轮，还剩一点余量）。
    /// 再多就要给轨加滚动，而一条要滚动的快捷入口轨本身就是设计失败。
    static let railCategoryLimit = 3
}

// ============================================================
// MARK: - 计数数据源
// ============================================================

/// 左侧两块共用的一份计数与列表。
///
/// 为什么要单独一个对象：这些数字背后是**七条聚合 SQL**（总数 / 今天 / 本周 /
/// 未加标签 / 已标注 / 分类 / 标签 / 应用）。轨和面板各自持一份 `@State` 再各自
/// `refresh()` 的话，每轮 store 变更就要跑两遍同样的查询。由 `GalleryLeftPanels`
/// 持有一份、两块都 `@ObservedObject` 读，一轮只跑一次。
///
/// 硬约束照旧：**聚合只在 `refresh()` 里跑，绝不进 body。**
/// `favoriteCount()` 是唯一的例外，它必须留在 body 里现读 —— 见 `refresh()` 的注释。
@MainActor
final class GalleryFilterCounts: ObservableObject {

    /// 分类 / 标签行：名字 + 数量。（`ShotStore` 返回的是元组，这里换成具名类型，
    /// `ForEach` 才有稳定的 `id`。）
    struct Entry: Identifiable, Hashable {
        let name: String
        let count: Int
        var id: String { name }
    }

    /// 应用行多一个 bundleID —— 真实 App 图标靠它解析。
    struct AppEntry: Identifiable, Hashable {
        let name: String
        let bundleID: String?
        let count: Int
        var id: String { name }
    }

    @Published private(set) var total = 0
    @Published private(set) var today = 0
    @Published private(set) var thisWeek = 0
    @Published private(set) var untagged = 0
    @Published private(set) var annotated = 0
    @Published private(set) var categories: [Entry] = []
    @Published private(set) var tags: [Entry] = []
    @Published private(set) var apps: [AppEntry] = []

    /// 轨上放的「高频分类」。
    ///
    /// **不在这里重新排序**：`ShotStore.categories()` 的 SQL 已经是
    /// `ORDER BY count DESC, name ASC`，在 Swift 里再排一遍就是第二份排序规则，
    /// 迟早和 SQL 漂移（面板里第一个和轨上第一个不是同一个分类，是最难查的那种 bug）。
    var railCategories: [Entry] {
        Array(categories.prefix(RailMetrics.railCategoryLimit))
    }

    /// 重查全部计数。
    ///
    /// 调用点只有一个（`GalleryLeftPanels` 的 `.task` + store 变更通知）。
    /// 通知发在 `reload()` 写库**之后**，所以这里直接读库拿到的已是新值。
    ///
    /// ⚠️ `favoriteCount()` 故意**不**搬进来：它读的是内存里的 `favoriteIDs`，
    /// 而那个集合是在 `objectWillChange` 发出**之后**才赋值的 —— 在这里读会慢一拍。
    /// 留在 body 里现读（它只是个 `Set.count`，不是查询），SwiftUI 重绘发生在
    /// 赋值之后，永远是新的。
    ///
    /// 八个 `@Published` 连续赋值不会引发八轮重绘：SwiftUI 把同一轮 runloop 里的
    /// 变更合并成一次更新。
    func refresh() {
        let store = ShotStore.shared
        total = store.totalCount
        today = store.todayCount()
        thisWeek = store.thisWeekCount()
        untagged = store.untaggedCount()
        annotated = store.annotatedCount()
        categories = store.categories().map { Entry(name: $0.name, count: $0.count) }
        tags = store.allTags().map { Entry(name: $0.name, count: $0.count) }
        apps = store.apps().map { AppEntry(name: $0.name, bundleID: $0.bundleID, count: $0.count) }
    }
}

// ============================================================
// MARK: - 分类图标 / 筛选落地
// ============================================================

/// 分类名 → SF Symbol。轨和面板共用：同一个分类在两处必须是同一个图标，
/// 否则「浏览器」在轨上是地球、在面板里是标签，用户会以为是两个东西。
enum GalleryCategoryIcon {

    static func symbol(_ name: String) -> String {
        switch name {
        case "代码": return "chevron.left.forwardslash.chevron.right"
        case "浏览器": return "globe"
        case "聊天": return "bubble.left.and.bubble.right"
        case "设计": return "paintpalette"
        case "终端": return "terminal"
        case "文档": return "doc.text"
        case "笔记": return "note.text"
        case "影音": return "play.rectangle"
        case "效率": return "checklist"
        default: return "tag"
        }
    }
}

/// 点某个筛选入口的**唯一**落地路径：写 `store.filter` + 重查。
///
/// 从前这是侧边栏 `List` 的 selection binding（`filterBinding`）。现在同一个筛选
/// 有两个入口（轨 + 面板），必须共用一份实现 —— 两份的结局一定是「有个入口忘了
/// reload」。已经选中的再点一次直接返回：省掉一次全量重查，也和 `List` 的
/// selection 语义（重选不触发）保持一致。
@MainActor
func selectGalleryFilter(_ filter: ShotStore.GalleryFilter) {
    let store = ShotStore.shared
    guard store.filter != filter else { return }
    store.filter = filter
    store.reload()
}

// ============================================================
// MARK: - 左侧一整块（轨 + 面板）
// ============================================================

/// 外壳左侧那一整块。`GalleryView` 只挂它，两块的宽度 / 缝 / 折叠状态都在这里。
struct GalleryLeftPanels: View {

    /// 标签面板的折叠状态。用 `@AppStorage` 而不是 `@State`：折叠与否是用户对
    /// 「我要不要那 176 点的宽度」的长期表态，和四个分组的开合同一性质，重启要还在。
    @AppStorage("galleryTagPanelExpanded") private var expanded = true

    /// 计数数据源。`@StateObject` —— 这一层是它的所有者，轨和面板只是读。
    @StateObject private var counts = GalleryFilterCounts()

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // ⚠️ 这里**没有** `@ObservedObject var store`：那会让轨 + 面板整块在每次
    // store 变更时重算 body。要的只是「变更了就重查计数」这一个副作用，
    // 所以直接订阅 `objectWillChange`（与 GalleryView 同一手法）。

    var body: some View {
        HStack(alignment: .top, spacing: RailMetrics.gap) {
            GalleryRail(expanded: $expanded, counts: counts)

            if expanded {
                GallerySidebar(counts: counts)
                    .frame(width: RailMetrics.panelWidth)
                    .frame(maxHeight: .infinity)
                    // `.overlay` 档：设计稿里这块是「叠在轨与内容之上」的卡片，
                    // 底色比轨亮一档、浅色下阴影更重。
                    .floatingPanel(level: .overlay)
                    // 向左收进轨里 + 淡出，读起来是「折回图标轨」而不是凭空消失。
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .frame(maxHeight: .infinity)
        // 三个入口（轨上的按钮、⌘\、拖放弹簧加载）自己都带 withAnimation ——
        // 那是为了把事务传到**父层**，让内容区变宽也走同一条曲线。这一行是兜底：
        // 将来有谁不经过那三个入口就写了 `expanded`（比如设置页加一个开关），
        // 面板也不会硬切。
        .animation(DS.Motion.standard(reduced: reduceMotion), value: expanded)
        .task { counts.refresh() }
        .onReceive(ShotStore.shared.objectWillChange) { _ in counts.refresh() }
    }
}

// ============================================================
// MARK: - 图标轨
// ============================================================

/// 设计稿 §2 的图标轨。
struct GalleryRail: View {

    @Binding var expanded: Bool
    @ObservedObject var counts: GalleryFilterCounts

    /// 只为两件事订阅 store：当前选中的 `filter`（决定哪个格子填 accent）
    /// 和 `favoriteCount()`。
    @ObservedObject private var store = ShotStore.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: DS.s2) {
            expandToggle
            entries
            // 齿轮固定在底部（设计稿 §2）：它不是筛选，不该混在筛选那一列里。
            Spacer(minLength: DS.s2)
            settingsButton
        }
        .padding(.vertical, DS.s3)
        .frame(width: RailMetrics.railWidth)
        .frame(maxHeight: .infinity)
        // 设计稿给的是圆角 20，token 里最接近的一档是 radiusFloating(18)。
        // 差 2 点，肉眼无差；新增一档 20 要动 DesignTokens，这一轮不许动。
        .floatingPanel(radius: DS.radiusFloating)
    }

    // MARK: 展开开关

    /// 轨顶的展开 / 收起按钮，兼 ⌘\ 的接收者，兼「弹簧加载」的投放感应区。
    private var expandToggle: some View {
        Button(action: toggle) {
            Image(systemName: "sidebar.leading")
        }
        .buttonStyle(.shellIcon(active: expanded))
        .keyboardShortcut("\\", modifiers: .command)
        .help(expanded ? "收起标签面板（⌘\\）" : "展开标签面板（⌘\\）")
        .accessibilityLabel("标签面板")
        .accessibilityValue(expanded ? "已展开" : "已收起")
        // 弹簧加载：面板收起时，拖着一批截图**悬停**在这个按钮上，面板自己弹开，
        // 于是标签行重新可达（macOS 拖到文件夹上停一下它会打开，同一个约定）。
        //
        // 载荷类型必须是 `ShotIDPayload`。**绝不能**写成 `ShotDragFile.self` 或
        // `URL.self`：那两个会触发 `FileRepresentation` 的导出闭包，把每张图的成品
        // PNG 现场渲染落盘 —— 就为了一次悬停。理由详见 GallerySidebar 的
        // `ShotDropTarget`。
        .dropDestination(for: ShotIDPayload.self) { _, _ in
            // 这个按钮**不收**投放，只借 isTargeted 做感应。收下就等于「拖到展开
            // 按钮上 = 打标签」，没有这种语义。
            false
        } isTargeted: { over in
            guard over, !expanded else { return }
            withAnimation(DS.Motion.standard(reduced: reduceMotion)) { expanded = true }
        }
    }

    /// 折叠 / 展开。`withAnimation` 写在这里而不是只靠 `.animation(value:)`：
    /// 折叠会让内容区变宽，那是**父层**的布局变化，得靠事务传出去才会一起动。
    private func toggle() {
        withAnimation(DS.Motion.standard(reduced: reduceMotion)) { expanded.toggle() }
    }

    // MARK: 格子

    @ViewBuilder
    private var entries: some View {
        RailItem(
            symbol: "square.grid.2x2",
            title: "全部截图",
            count: counts.total,
            isSelected: store.filter == .all
        ) {
            selectGalleryFilter(.all)
        }

        RailItem(
            symbol: "star",
            title: "收藏",
            tint: .yellow,
            // 内存里的 Set.count，不是查询 —— 留在 body 里现读是对的，
            // 理由见 `GalleryFilterCounts.refresh()`。
            count: store.favoriteCount(),
            isSelected: store.filter == .favorites
        ) {
            selectGalleryFilter(.favorites)
        }
        // 面板收起时这里是收藏投放的**唯一**入口，所以轨上必须有它。
        .modifier(ShotDropTarget(fillsWidth: false) { GalleryDropActions.markFavorite($0) })

        ForEach(counts.railCategories) { category in
            RailItem(
                symbol: GalleryCategoryIcon.symbol(category.name),
                title: category.name,
                tint: DS.categoryColor(category.name),
                count: category.count,
                isSelected: store.filter == .category(category.name)
            ) {
                selectGalleryFilter(.category(category.name))
            }
        }
    }

    // MARK: 设置

    private var settingsButton: some View {
        Button {
            NSApp.sendAction(#selector(GalleryRailSettingsAction.openSettings), to: nil, from: nil)
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 16, weight: .medium))
        }
        .buttonStyle(ShellIconButtonStyle(side: RailMetrics.iconSide))
        .help("设置")
        .accessibilityLabel("设置")
    }
}

/// 只用来取一个编译期检查过拼写的 selector（和 GalleryTopBar 里那个同一条路：
/// 设置窗口归 `AppDelegate` 开，UI/ 不许直接碰 Settings/ 的窗口控制器）。
///
/// 名字带 `GalleryRail` 前缀是必须的：`@objc` 协议名会原样注册进 ObjC 运行时，
/// 同一个二进制里出现两个都叫 `SettingsAction` 的协议是重复定义。
@objc private protocol GalleryRailSettingsAction {
    func openSettings()
}

// ============================================================
// MARK: - 轨上的一格
// ============================================================

/// 44×44 圆角方图标 + 下方小号计数（设计稿 §2）。
private struct RailItem: View {

    let symbol: String
    let title: String
    var tint: Color?
    let count: Int
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        VStack(spacing: 2) {
            Button(action: action) {
                icon
            }
            // 选中 = accent 实心 + 图标转白，正是 `ShellIconButtonStyle` 的 isActive；
            // 悬停浮出底色、按下微缩也一并拿到，不用自己再写一遍。
            .buttonStyle(ShellIconButtonStyle(isActive: isSelected, side: RailMetrics.iconSide))
            .help(title)
            // 屏幕上只有图标和数字，名字只在 tooltip 里 —— 无障碍标签必须把
            // 名字和数量一起说全，并且这一句挂在**按钮**上（可聚焦的那个元素）。
            .accessibilityLabel(count > 0 ? "\(title)，\(count) 张" : title)
            .accessibilityAddTraits(isSelected ? [.isSelected] : [])

            countLabel
        }
    }

    @ViewBuilder
    private var icon: some View {
        // 分类色染在图标上（面板里也是这么做的，§7.1 允许 —— 分类色不参与深度表达）。
        // 但**选中时不染**：`ShellIconButtonStyle` 在外层把前景设为白，
        // 而 SwiftUI 里内层的 `foregroundStyle` 优先 —— 染了就白不了。
        if let tint, !isSelected {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(tint)
        } else {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
        }
    }

    /// 图标下方的计数（11pt 灰）。
    ///
    /// **高度写死**：数字为 0 时留空而不是整格塌掉 —— 面板收起后这一列数字是
    /// 计数的唯一去处，行高随数据跳变会让整条轨上下抖（和面板里「计数为 0 保留
    /// 该行」是同一条理由：导航骨架不许随数据变形）。
    ///
    /// `accessibilityHidden`：数量已经念在按钮的标签里了，再单独念一个光秃秃的
    /// 数字是噪音。
    private var countLabel: some View {
        Text(count > 0 ? "\(count)" : "")
            .font(.system(size: 11))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(height: 13)
            .accessibilityHidden(true)
    }
}
