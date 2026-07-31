import SwiftUI
import AppKit

// MARK: - 标签面板（图标轨的展开态）
//
// 设计稿 §3：图标轨右侧那块 168 宽的浮动圆角卡片。内容是四组筛选入口的**全量**
// 列表 —— 资料库（今天/本周/收藏/未加标签/已标注）/ 分类 / 标签 / 应用，
// 每行「图标 + 名称 + 右对齐计数」，选中行是浅色圆底。标签的重命名与删除在这里；
// 标签行与收藏行还是投放目标：从网格里拖一批卡片过来即完成打标签 / 批量收藏。
// 附带面板专用的 App 图标视图与其缓存。
//
// 轨上放什么、面板放什么，以及面板收起时投放目标怎么还能用，见 GalleryRail.swift
// 的文件注释。计数与列表由 `GalleryFilterCounts` 统一供给（轨和面板共用一份，
// 那几条聚合 SQL 一轮只跑一次）。
//
// 关于材质：这块面板**不上 Material**。底色是 `DS.panelFill(.overlay)` 纯色
// + rim 渐变描边，由容器那侧的 `.floatingPanel(level:)` 施加。
// 三条理由（这段以前写的是「材质由 NavigationSplitView 自动提供、手加就浑浊」，
// 那个前提已经不成立 —— 外壳改成自绘浮动面板之后侧边栏根本不在 split view 里，
// 系统一点材质都不给了）：
//   1. 现在的风险反过来：手加材质是**新增**一个 behindWindow 材质，而每窗口
//      只允许一个（SpatialModifiers 铁律 2），这套布局同屏面板有三四块。
//   2. 窗口底不透明（`isOpaque` 没关），面板底下没有桌面可借 —— 材质只会
//      采样到自家底色，白付一份模糊。
//   3. 纯色顺带让 ReduceTransparency 不需要降级分支：本来就是实色。
//
// 另外 `List(.sidebar)` 也一并换成了 ScrollView + 自绘行：它的行高不受控、
// 选中态是 accent 实心（设计稿要的是浅色圆底），而且它自带一层不透明底会盖住
// 面板的底色（原先要靠调用方加 `.scrollContentBackground(.hidden)` 才压得住）。
// 代价说清楚：丢掉了 `List` 的原生行键盘导航（`GalleryKeyboard` 里给 NSTableView
// 放行方向键那条分支对本面板不再生效），换来的是设计稿要求的行规格。

struct GallerySidebar: View {

    /// 计数与列表的唯一真相。由 `GalleryLeftPanels` 持有，这里只读。
    @ObservedObject var counts: GalleryFilterCounts

    /// 只为两件事订阅 store：当前 `filter`（决定哪一行有底）和 `favoriteCount()`。
    @ObservedObject private var store = ShotStore.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // 四个分组的展开状态。用 @AppStorage 而不是 @State：分组开合是用户对
    // 「我平时关心哪几类」的表态，属于长期偏好，重启后应当还在。
    @AppStorage("sidebarLibraryExpanded") private var libraryExpanded = true
    @AppStorage("sidebarCategoriesExpanded") private var categoriesExpanded = true
    @AppStorage("sidebarTagsExpanded") private var tagsExpanded = true

    /// 右键「重命名」弹窗的目标标签，非 nil 即弹窗。
    @State private var renamingTag: String?
    @State private var renameText = ""
    /// 右键「删除」确认的目标标签。
    @State private var deletingTag: String?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: DS.s3) {
                librarySection
                categoriesSection
                tagsSection
            }
            .padding(.vertical, DS.s3)
        }
        // ScrollView 在 macOS 上会垫一层不透明的 windowBackgroundColor，
        // 不关掉会盖住面板自己的底色（两种灰打架）。以前这行写在 GalleryView 上，
        // 现在面板自己的事自己管。
        .scrollContentBackground(.hidden)
        .alert(
            "重命名标签",
            isPresented: Binding(
                get: { renamingTag != nil },
                set: { if !$0 { renamingTag = nil } }
            ),
            presenting: renamingTag
        ) { tag in
            TextField("标签名", text: $renameText)
            // .alert 里塞不下内联的错误标签（内容只认 TextField / Button），
            // 所以校验分两处落地：按钮禁用挡住提交，message 说清为什么。
            // 动作闭包里再守一次 —— 正确性不能只押在 .disabled 的渲染上。
            Button("重命名") {
                guard canRename(tag) else { return }
                store.renameTag(tag, to: renameText)
            }
            .disabled(!canRename(tag))
            Button("取消", role: .cancel) {}
        } message: { tag in
            Text(renameIssue(for: tag) ?? "所有打了「\(tag)」的截图都会改用新名字。")
        }
        .alert(
            "删除标签「\(deletingTag ?? "")」？",
            isPresented: Binding(
                get: { deletingTag != nil },
                set: { if !$0 { deletingTag = nil } }
            ),
            presenting: deletingTag
        ) { tag in
            Button("删除", role: .destructive) { store.deleteTag(tag) }
            Button("取消", role: .cancel) {}
        } message: { _ in
            Text("只移除标签本身，截图不会被删除。")
        }
    }

    // MARK: - 四组

    @ViewBuilder
    private var librarySection: some View {
        // 顺序 = 使用频度。「全部」是默认落点；「今天 / 本周」是刚截完图
        // 最常回头找的两个窗口；「收藏」是手动精选；最后两个是整理动作的
        // 入口 —— 「未加标签」是从哪开始整理，「已标注」是找加工过的图。
        section("资料库", isExpanded: $libraryExpanded) {
            filterRow(.all, title: "全部截图", symbol: "square.grid.2x2", count: counts.total)
            // 这里曾经还有「今天 / 本周」两行。删掉的理由：网格本来就按日期分组
            // （今天 / 昨天 / 更早的段头）并且最新在最上 —— 「今天」等于滚到顶，
            // 它多出来的只是「把更早的藏起来」，不值一个常驻行位。
            filterRow(
                .favorites, title: "收藏", symbol: "star",
                tint: .yellow, count: store.favoriteCount()
            )
            .modifier(ShotDropTarget { GalleryDropActions.markFavorite($0) })
            filterRow(.untagged, title: "未加标签", symbol: "tag.slash", count: counts.untagged)
            // 口径与卡片右下角的铅笔角标一致（修订数 > 1），图标也用同一个 pencil。
            filterRow(.annotated, title: "已标注", symbol: "pencil", count: counts.annotated)
        }
    }

    @ViewBuilder
    private var categoriesSection: some View {
        if !counts.categories.isEmpty {
            section("分类", isExpanded: $categoriesExpanded) {
                ForEach(counts.categories) { category in
                    // 原来是「8pt 色点 + 单色图标 + 名称 + 徽章」四件套，
                    // 色点和图标在说同一件事。把分类色直接染到图标上，
                    // 一行只剩三个元素，扫读时眼睛少停一次。
                    // （§7.1 的约束是分类色不参与深度表达，染图标不违反。）
                    filterRow(
                        .category(category.name),
                        title: category.name,
                        symbol: GalleryCategoryIcon.symbol(category.name),
                        tint: DS.categoryColor(category.name),
                        count: category.count
                    )
                }
            }
        }
    }

    /// 用户自己的组织方式排在自动分类后面；一个标签都没有时整区不出现。
    @ViewBuilder
    private var tagsSection: some View {
        if !counts.tags.isEmpty {
            section("标签", isExpanded: $tagsExpanded) {
                ForEach(counts.tags) { tag in
                    filterRow(.tag(tag.name), title: tag.name, symbol: "tag", count: tag.count)
                        .modifier(ShotDropTarget { GalleryDropActions.applyTag(tag.name, to: $0) })
                        .contextMenu {
                            Button("重命名…") {
                                renameText = tag.name
                                renamingTag = tag.name
                            }
                            Button("删除标签…", role: .destructive) {
                                deletingTag = tag.name
                            }
                        }
                }
            }
        }
    }

    // 这里曾经有一个「应用」分组，按来源 App 逐个列出来。删掉的理由有三条：
    //   · 它和「分类」是同一个维度的两种粒度 —— 分类本来就是从来源 App 推出来的，
    //     两组并排等于把同一件事说两遍（这正是上一轮清掉的那类重复）；
    //   · 长尾极重：实测一个真实库里 17 个应用、大多数只有 1 张截图，
    //     为此还得配一个「显示全部（N 个）」的截断开关；
    //   · 能力没丢 —— 应用名进了全文索引，搜「Edge」就是按应用筛。
    // 连带删掉的还有侧边栏专用的那份 App 图标缓存（详情面板另有一份，
    // 两份 NSCache 各存一份 NSImage 是记录在案的债）。

    /// 一个可折叠分组：头（标题 + 三角）+ 行。
    ///
    /// 手写而不是 `Section(isExpanded:)` —— 那个 API 只在 `List` 里有，
    /// 而 `List` 已经因为行高与选中态被换掉了（见文件顶部）。
    @ViewBuilder
    private func section<Content: View>(
        _ title: String,
        isExpanded: Binding<Bool>,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: RailMetrics.rowSpacing) {
            Button {
                // 折叠整组 = 一次进出好几行的布局切换，按 §6 归 standard 档。
                withAnimation(DS.Motion.standard(reduced: reduceMotion)) {
                    isExpanded.wrappedValue.toggle()
                }
            } label: {
                HStack(spacing: DS.s1) {
                    Text(title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded.wrappedValue ? 0 : -90))
                }
                .padding(.horizontal, DS.s2)
                .frame(height: 26)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityValue(isExpanded.wrappedValue ? "已展开" : "已收起")

            if isExpanded.wrappedValue {
                content()
            }
        }
        .padding(.horizontal, DS.s2)
    }

    // MARK: - 行

    /// 一行筛选入口：图标 + 名称 + 右对齐计数 + 选中态。
    ///
    /// 计数为 0 时**保留该行、只是压暗**，不隐藏。理由：
    /// 「资料库」这六行是导航骨架，行数随数据跳变会毁掉肌肉记忆 ——
    /// 过了零点「今天」凭空少一行、下面所有行整体上移，是最难受的一种抖动。
    /// 而且「未加标签 = 0」本身就是有价值的信号（整理干净了），藏起来等于把
    /// 好消息也藏了。计数为 0 时数字本身不画（见 `PanelRow`）。
    private func row<Icon: View>(
        _ filter: ShotStore.GalleryFilter,
        title: String,
        count: Int,
        @ViewBuilder icon: () -> Icon
    ) -> some View {
        PanelRow(
            title: title,
            count: count,
            isSelected: store.filter == filter,
            isDimmed: count == 0 && store.filter != filter,
            action: { selectGalleryFilter(filter) },
            icon: icon
        )
    }

    /// SF Symbol 版的行（应用行走 `row(...)`，它的图标是真实 App 图标）。
    private func filterRow(
        _ filter: ShotStore.GalleryFilter,
        title: String,
        symbol: String,
        tint: Color? = nil,
        count: Int
    ) -> some View {
        row(filter, title: title, count: count) {
            if let tint {
                Image(systemName: symbol).foregroundStyle(tint)
            } else {
                Image(systemName: symbol)
            }
        }
    }

    // MARK: - 校验

    /// 重命名可提交吗。空白名、没改动、与现有标签重名，三种情况都不放行。
    private func canRename(_ old: String) -> Bool {
        renameIssue(for: old) == nil && trimmedRenameText != old
    }

    /// 不能提交的原因，可提交时为 nil。「没改动」不算错误，所以不在这里报。
    private func renameIssue(for old: String) -> String? {
        let name = trimmedRenameText
        if name.isEmpty { return "标签名不能为空。" }
        if name == old { return nil }
        if counts.tags.contains(where: { $0.name == name }) {
            return "已经有一个叫「\(name)」的标签了，换个名字。"
        }
        return nil
    }

    private var trimmedRenameText: String {
        renameText.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - 面板的一行

/// 图标 + 名称 + 右对齐计数，选中态是浅色圆底（设计稿 §3）。
///
/// 单独一个视图而不是一个 `@ViewBuilder` 函数：悬停态需要 `@State`，
/// 而函数里的 `@State` 会串（没有视图身份）。
private struct PanelRow<Icon: View>: View {

    let title: String
    let count: Int
    let isSelected: Bool
    /// 空分类 / 空智能入口：保留行但压暗（理由见 `GallerySidebar.row`）。
    let isDimmed: Bool
    let action: () -> Void
    private let icon: Icon

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    init(
        title: String,
        count: Int,
        isSelected: Bool,
        isDimmed: Bool = false,
        action: @escaping () -> Void,
        @ViewBuilder icon: () -> Icon
    ) {
        self.title = title
        self.count = count
        self.isSelected = isSelected
        self.isDimmed = isDimmed
        self.action = action
        self.icon = icon()
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: DS.s2) {
                icon
                    .font(.system(size: 13))
                    .frame(width: 18, height: 18)
                Text(title)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    // 标签名可能很长（面板只有 168 宽）。中间截断比尾部截断
                    // 更容易分辨两个前缀相同的名字。
                    .truncationMode(.middle)
                Spacer(minLength: DS.s1)
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, DS.s2)
            .frame(height: RailMetrics.rowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(fill, in: shape)
            .contentShape(shape)
            .opacity(isDimmed ? 0.5 : 1)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(DS.Motion.micro(reduced: reduceMotion), value: hovering)
        .accessibilityLabel(count > 0 ? "\(title)，\(count) 张" : title)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    /// 选中 = 浅色圆底，**不是** accent 实心。
    /// accent 在这套设计里归图标轨的选中格（§2）和网格的选中卡；
    /// 同屏第三处上强调色就乱了（§7.1：最多一个控件加色）。
    /// 深浅两侧都走「亮度阶梯」那一套：深色加白、浅色加黑。
    private var fill: Color {
        if isSelected {
            return scheme == .dark ? .white.opacity(0.11) : .black.opacity(0.075)
        }
        if hovering {
            return scheme == .dark ? .white.opacity(0.06) : .black.opacity(0.04)
        }
        return .clear
    }
}

// MARK: - 投放目标

/// 侧边栏行 / 图标轨格子的「接收一批截图」能力：高亮反馈 + 收下 ID 集合。
///
/// 只认 `ShotIDPayload`（一串 Int64）。**绝不能写成 `for: ShotDragFile.self`
/// 或 `for: URL.self`** —— 那两个会触发 `FileRepresentation` 的导出闭包，
/// 把每张图的成品 PNG 现场渲染落盘。拖 50 张就是 50 次「解码 + 合成 + 编码 + 写盘」，
/// 全在主线程上，这正是当年拖垮图库滚动的那条路。
///
/// 不再是 `private`：图标轨上的收藏格也要它（面板收起时那是收藏投放的唯一入口），
/// 而轨在另一个文件里。
struct ShotDropTarget: ViewModifier {

    /// 高亮块的圆角。默认对上面板行选中底和轨上按钮的圆角（都是 `radiusCard`），
    /// 高亮和选中底必须严丝合缝地重合，差一点就会看出两个矩形。
    var radius: CGFloat = DS.radiusCard
    /// 面板行要撑满面板宽（拖到行的右半边也该接得住）；
    /// 轨上的格子是 44 宽的方块，撑满就会溢出到轨外面。
    var fillsWidth: Bool = true

    let perform: (Set<Int64>) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isTargeted = false

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: fillsWidth ? .infinity : nil, alignment: .leading)
            .contentShape(Rectangle())
            .background {
                // 反馈只用 accent 的填充 + 描边，不加材质、不加阴影：面板本身就是
                // 一块纯色浮起卡片（见文件顶部），在它上面叠材质是白付一份模糊。
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Color.accentColor.opacity(isTargeted ? 0.20 : 0))
                    .overlay {
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .strokeBorder(
                                Color.accentColor.opacity(isTargeted ? 0.55 : 0),
                                lineWidth: 1
                            )
                    }
                    .allowsHitTesting(false)
            }
            .animation(DS.Motion.micro(reduced: reduceMotion), value: isTargeted)
            .dropDestination(for: ShotIDPayload.self) { payloads, _ in
                let ids = Set(payloads.flatMap(\.shotIDs))
                guard !ids.isEmpty else { return false }
                perform(ids)
                return true
            } isTargeted: { over in
                isTargeted = over
            }
    }
}

/// 投放落地的两个动作。轨和面板都要用，所以是共享的静态方法而不是各写一份 ——
/// 「拖到收藏上要不要写 searchableText」这种事只能有一个答案。
@MainActor
enum GalleryDropActions {

    /// 把一批截图打上标签。
    ///
    /// 幂等由数据层保证：`ShotStore.addTag` 插行前先 `SELECT EXISTS`
    /// （v4 迁移为了支持多值标签移除了 UNIQUE 约束，所以判重必须在应用层做）。
    /// 重复投放同一批图不会长出第二行。
    ///
    /// 逐张调用是唯一选择（数据层没有批量入口），但不会引发 reload 风暴：
    /// `addTag` 走的 `setNeedsReload()` 是 leading + trailing 节流 ——
    /// 循环里第一次可能立即刷一轮，其余全部合并成尾部的一次，
    /// 拖 50 张最多两轮全量刷新，不是 50 轮。
    static func applyTag(_ tag: String, to ids: Set<Int64>) {
        let store = ShotStore.shared
        for id in ids {
            store.addTag(shotID: id, tag)
        }
    }

    /// 批量收藏。已经是收藏的跳过（幂等，也省掉一次没必要的写事务）。
    /// `searchableText` 必须是 nil，理由同 `ShotStore.toggleFavorite`：
    /// 收藏是标记不是内容，进了 attributeFts 会让全文搜索命中所有收藏。
    static func markFavorite(_ ids: Set<Int64>) {
        let store = ShotStore.shared
        for id in ids where !store.isFavorite(shotID: id) {
            store.writeAttribute(
                shotID: id,
                key: AttributeKey.favorite,
                value: .data(Data([1]), searchableText: nil)
            )
        }
    }
}

// App 图标的解析与缓存曾经在这里也有一份（面板的「应用」分组用）。
// 那个分组删掉之后，全项目只剩详情面板那一份 `AppIconProvider` ——
// 「两份 NSCache 各存一份 NSImage」这笔记录在案的债顺带清了。
