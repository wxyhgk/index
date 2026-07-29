import SwiftUI
import AppKit

// MARK: - 侧边栏
//
// 图库左栏：资料库（含四个智能入口）/ 分类 / 标签 / 应用四组筛选入口
// （带计数与真实 App 图标），标签的重命名与删除也在这里。
// 标签行与收藏行还是投放目标：从网格里拖一批卡片过来即完成打标签 / 批量收藏。
// 附带侧边栏专用的 App 图标视图与其缓存。

// 关于材质：这里**故意什么都不加**。侧边栏的 sidebar 材质 + vibrancy 由
// NavigationSplitView 自动提供（见 GalleryView.gallery），手加 Material 就是
// 「材质叠材质」，结果是浑浊而不是更透 —— 那是这套设计里最常见的一个坑。
struct GallerySidebar: View {

    @ObservedObject private var store = ShotStore.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var categories: [(name: String, count: Int)] = []
    @State private var tags: [(name: String, count: Int)] = []
    @State private var apps: [(name: String, bundleID: String?, count: Int)] = []
    @State private var total = 0
    @State private var smart = SmartCounts()

    // 四个分组的展开状态。用 @AppStorage 而不是 @State：侧边栏的分组开合是
    // 用户对「我平时关心哪几类」的表态，属于长期偏好，重启后应当还在。
    @AppStorage("sidebarLibraryExpanded") private var libraryExpanded = true
    @AppStorage("sidebarCategoriesExpanded") private var categoriesExpanded = true
    @AppStorage("sidebarTagsExpanded") private var tagsExpanded = true
    @AppStorage("sidebarAppsExpanded") private var appsExpanded = true

    /// 应用组内部的「只显示前 5 个」。和上面的分组开合是两回事：
    /// 分组开合表达「我关不关心应用这一类」，这个表达「一次看几个」，
    /// 是一次性的浏览动作，不进偏好。
    @State private var appsShowingAll = false
    /// 右键「重命名」弹窗的目标标签，非 nil 即弹窗。
    @State private var renamingTag: String?
    @State private var renameText = ""
    /// 右键「删除」确认的目标标签。
    @State private var deletingTag: String?

    /// 四个智能入口的徽章数。它们背后都是聚合 SQL，绝不能放在 body 里
    /// 每帧现查 —— 统一在 refresh() 里算一次存下来。
    /// （`favoriteCount()` 是内存里的 Set，是唯一留在 body 里现读的，
    /// 理由见 refresh() 的注释。）
    private struct SmartCounts {
        var today = 0
        var thisWeek = 0
        var untagged = 0
        var annotated = 0
    }

    /// 应用组是否需要内部截断（8 个以内没必要）。
    private var appsCollapsible: Bool { apps.count > 8 }

    private var visibleApps: [(name: String, bundleID: String?, count: Int)] {
        appsCollapsible && !appsShowingAll ? Array(apps.prefix(5)) : apps
    }

    var body: some View {
        List(selection: filterBinding) {
            // 顺序 = 使用频度。「全部」是默认落点；「今天 / 本周」是刚截完图
            // 最常回头找的两个窗口；「收藏」是手动精选；最后两个是整理动作的
            // 入口 —— 「未加标签」是从哪开始整理，「已标注」是找加工过的图。
            Section(isExpanded: $libraryExpanded) {
                filterRow(.all, title: "全部截图", symbol: "square.grid.2x2", count: total)
                filterRow(.today, title: "今天", symbol: "clock", count: smart.today)
                filterRow(.thisWeek, title: "本周", symbol: "calendar", count: smart.thisWeek)
                filterRow(
                    .favorites, title: "收藏", symbol: "star",
                    tint: .yellow, count: store.favoriteCount()
                )
                .modifier(ShotDropTarget { markFavorite($0) })
                filterRow(.untagged, title: "未加标签", symbol: "tag.slash", count: smart.untagged)
                // 口径与卡片右下角的铅笔角标一致（修订数 > 1），图标也用同一个 pencil。
                filterRow(.annotated, title: "已标注", symbol: "pencil", count: smart.annotated)
            } header: {
                Text("资料库")
            }

            if !categories.isEmpty {
                Section(isExpanded: $categoriesExpanded) {
                    ForEach(categories, id: \.name) { category in
                        // 原来是「8pt 色点 + 单色图标 + 名称 + 徽章」四件套，
                        // 色点和图标在说同一件事。把分类色直接染到图标上，
                        // 一行只剩三个元素，扫读时眼睛少停一次。
                        // （§7.1 的约束是分类色不参与深度表达，染图标不违反。）
                        filterRow(
                            .category(category.name),
                            title: category.name,
                            symbol: icon(forCategory: category.name),
                            tint: DS.categoryColor(category.name),
                            count: category.count
                        )
                    }
                } header: {
                    Text("分类")
                }
            }

            // 用户自己的组织方式排在自动分类后面；一个标签都没有时整区不出现。
            if !tags.isEmpty {
                Section(isExpanded: $tagsExpanded) {
                    ForEach(tags, id: \.name) { tag in
                        filterRow(
                            .tag(tag.name), title: tag.name,
                            symbol: "tag", count: tag.count
                        )
                        .modifier(ShotDropTarget { applyTag(tag.name, to: $0) })
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
                } header: {
                    Text("标签")
                }
            }

            if !apps.isEmpty {
                Section(isExpanded: $appsExpanded) {
                    ForEach(visibleApps, id: \.name) { app in
                        HStack(spacing: DS.s2) {
                            AppIconView(bundleID: app.bundleID)
                            Text(app.name).lineLimit(1)
                        }
                        .badge(app.count)
                        .tag(ShotStore.GalleryFilter.app(app.name))
                    }
                    if appsCollapsible {
                        Button {
                            // 展开/收起是一次列表布局切换（一次进出好几行），
                            // 按 §6 归 standard 档；micro 太快会让新行「闪」出来。
                            withAnimation(DS.Motion.standard(reduced: reduceMotion)) {
                                appsShowingAll.toggle()
                            }
                        } label: {
                            // 图标刻意不用 chevron：分组头上的三角现在归「折叠整组」，
                            // 这里是「同一组里多看几行」，两件事不该共用一个符号。
                            Label(
                                appsShowingAll ? "收起" : "显示全部（\(apps.count) 个）",
                                systemImage: appsShowingAll ? "chevron.up" : "ellipsis"
                            )
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .selectionDisabled()
                    }
                } header: {
                    Text("应用")
                }
            }
        }
        .listStyle(.sidebar)
        // 聚合是几条小查询。标签的增删改不改变 shots 的数量，
        // 只跟数据量刷新会漏 —— 改订 store 的变更通知，每次都重查。
        // 通知发在 reload() 写库**之后**，这里直接读库拿到的已是新值。
        .task { refresh() }
        .onReceive(store.objectWillChange) { _ in refresh() }
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

    // MARK: - 行

    /// 一行筛选入口：图标（可染色）+ 名称 + 徽章 + selection tag。
    ///
    /// 计数为 0 时**保留该行、只是压暗**，不隐藏。理由：
    /// 「资料库」这六行是导航骨架，行数随数据跳变会毁掉肌肉记忆 ——
    /// 过了零点「今天」凭空少一行、下面所有行整体上移，是最难受的一种抖动。
    /// 而且「未加标签 = 0」本身就是有价值的信号（整理干净了），藏起来等于把
    /// 好消息也藏了。徽章交给 SwiftUI：`.badge(0)` 自己就不画。
    private func filterRow(
        _ filter: ShotStore.GalleryFilter,
        title: String,
        symbol: String,
        tint: Color? = nil,
        count: Int
    ) -> some View {
        Label {
            Text(title).lineLimit(1)
        } icon: {
            if let tint {
                Image(systemName: symbol).foregroundStyle(tint)
            } else {
                Image(systemName: symbol)
            }
        }
        // 只在未选中时压暗：选中态的前景色由 List 接管，再叠透明度会把
        // 系统给的高对比文字弄脏。
        .opacity(count == 0 && store.filter != filter ? 0.5 : 1)
        .badge(count)
        .tag(filter)
    }

    /// List 的 selection 是可选的，而筛选永远有值（默认「全部」）—— 在这里桥一下。
    private var filterBinding: Binding<ShotStore.GalleryFilter?> {
        Binding(
            get: { store.filter },
            set: { newValue in
                store.filter = newValue ?? .all
                store.reload()
            }
        )
    }

    // MARK: - 投放

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
    private func applyTag(_ tag: String, to ids: Set<Int64>) {
        for id in ids {
            store.addTag(shotID: id, tag)
        }
    }

    /// 批量收藏。已经是收藏的跳过（幂等，也省掉一次没必要的写事务）。
    /// `searchableText` 必须是 nil，理由同 `ShotStore.toggleFavorite`：
    /// 收藏是标记不是内容，进了 attributeFts 会让全文搜索命中所有收藏。
    private func markFavorite(_ ids: Set<Int64>) {
        for id in ids where !store.isFavorite(shotID: id) {
            store.writeAttribute(
                shotID: id,
                key: AttributeKey.favorite,
                value: .data(Data([1]), searchableText: nil)
            )
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
        if tags.contains(where: { $0.name == name }) {
            return "已经有一个叫「\(name)」的标签了，换个名字。"
        }
        return nil
    }

    private var trimmedRenameText: String {
        renameText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 数据

    private func refresh() {
        total = store.totalCount
        // 这四个是聚合 SQL。写事务在 setNeedsReload() 之前就已提交，
        // 所以即便本回调是在 objectWillChange（早于赋值）里跑的，
        // 读库拿到的也是新值。
        //
        // ⚠️ `favoriteCount()` 故意**不**搬进来：它读的是内存里的 favoriteIDs，
        // 而那个集合是在 objectWillChange 发出之后才赋值的 —— 在这里读会慢一拍。
        // 留在 body 里现读，SwiftUI 重绘发生在赋值之后，永远是新的。
        smart = SmartCounts(
            today: store.todayCount(),
            thisWeek: store.thisWeekCount(),
            untagged: store.untaggedCount(),
            annotated: store.annotatedCount()
        )
        categories = store.categories()
        tags = store.allTags()
        apps = store.apps()
    }

    private func icon(forCategory name: String) -> String {
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

// MARK: - 投放目标

/// 侧边栏行的「接收一批截图」能力：高亮反馈 + 收下 ID 集合。
///
/// 只认 `ShotIDPayload`（一串 Int64）。**绝不能写成 `for: ShotDragFile.self`
/// 或 `for: URL.self`** —— 那两个会触发 `FileRepresentation` 的导出闭包，
/// 把每张图的成品 PNG 现场渲染落盘。拖 50 张就是 50 次「解码 + 合成 + 编码 + 写盘」，
/// 全在主线程上，这正是当年拖垮图库滚动的那条路。
private struct ShotDropTarget: ViewModifier {

    let perform: (Set<Int64>) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isTargeted = false

    func body(content: Content) -> some View {
        content
            // 撑满行宽，让高亮块和命中区都覆盖整行而不是只包住文字 ——
            // 拖到行的右半边也该接得住。
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background {
                // 反馈只用 accent 的填充 + 描边，不加材质、不加阴影：
                // 侧边栏已经在系统材质上了（见文件顶部），再叠一层就是玻璃叠玻璃。
                RoundedRectangle(cornerRadius: DS.radiusSmall, style: .continuous)
                    .fill(Color.accentColor.opacity(isTargeted ? 0.20 : 0))
                    .overlay {
                        RoundedRectangle(cornerRadius: DS.radiusSmall, style: .continuous)
                            .strokeBorder(
                                Color.accentColor.opacity(isTargeted ? 0.55 : 0),
                                lineWidth: 1
                            )
                    }
                    .padding(.horizontal, -DS.s1)
                    .padding(.vertical, -2)
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

// MARK: - App 图标

/// 侧边栏里的真实 App 图标。按 bundleID 解析一次后缓存。
private struct AppIconView: View {
    let bundleID: String?

    @State private var icon: NSImage?

    var body: some View {
        Group {
            if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 16, height: 16)
            } else {
                Image(systemName: "app.dashed")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
            }
        }
        .task(id: bundleID) {
            // 命中缓存这条路径**没有 await**：同一次 runloop 里就赋上值，
            // 已解析过的图标不会先闪一下占位符再变出来。
            if let hit = AppIconCache.shared.cached(bundleID) {
                icon = hit
                return
            }
            icon = await AppIconCache.shared.icon(for: bundleID)
        }
    }
}

/// NSImage 不是 Sendable。这里的实例是 detached task 里现造的，造完就交出去、
/// 自己不再持有也不再改 —— 是一次所有权转移而不是共享。用盒子把这件事讲明白，
/// 而不是在调用处埋一个静默的 @unchecked。
private struct AppIconBox: @unchecked Sendable {
    let image: NSImage?
}

@MainActor
private final class AppIconCache {
    static let shared = AppIconCache()

    /// 换掉原来的 `[String: NSImage]`：那份字典永不淘汰，
    /// 一台装了几百个 App 的机器上只会一直涨。NSCache 有条数上限，
    /// 且系统内存吃紧时会自己放手。
    private let cache = NSCache<NSString, NSImage>()
    /// 同一个 bundleID 的并发解析只跑一次 —— 侧边栏刷新时几十行会同时发起。
    private var inflight: [String: Task<AppIconBox, Never>] = [:]

    private init() {
        cache.countLimit = 128
    }

    /// 同步取缓存。只命中，不解析 —— 给视图做「无闪烁」快路径用。
    func cached(_ bundleID: String?) -> NSImage? {
        guard let bundleID else { return nil }
        return cache.object(forKey: bundleID as NSString)
    }

    /// 解析并缓存。
    ///
    /// `NSWorkspace.icon(forFile:)` 要去 App bundle 里读 .icns，是一次同步磁盘 IO；
    /// 原来它按行在主线程上串行跑，装的应用一多首屏就顿一下。挪进 detached task
    /// 之后主线程只剩一次赋值。
    ///
    /// 取舍：`NSWorkspace` 的这两个查询走 LaunchServices，实践上可以离开主线程；
    /// Apple 没有白纸黑字的保证，但代价（首屏卡顿）是确定的。
    /// 另外**不再改 `icon.size`** —— 显示尺寸由 `.resizable().frame()` 决定，
    /// 那行赋值本来就是多余的，而 `icon(forFile:)` 返回的实例有可能是 AppKit
    /// 内部共享的，在后台线程上改它的属性是没必要冒的险。
    func icon(for bundleID: String?) async -> NSImage? {
        guard let bundleID else { return nil }
        if let hit = cache.object(forKey: bundleID as NSString) { return hit }

        let task: Task<AppIconBox, Never>
        if let running = inflight[bundleID] {
            task = running
        } else {
            task = Task.detached(priority: .userInitiated) {
                guard let url = NSWorkspace.shared
                    .urlForApplication(withBundleIdentifier: bundleID) else {
                    return AppIconBox(image: nil)
                }
                return AppIconBox(image: NSWorkspace.shared.icon(forFile: url.path))
            }
            inflight[bundleID] = task
        }

        let image = await task.value.image
        inflight[bundleID] = nil
        if let image {
            cache.setObject(image, forKey: bundleID as NSString)
        }
        return image
    }
}
