import SwiftUI
import AppKit
import UniformTypeIdentifiers

@MainActor
final class GallerySelection: ObservableObject {
    static let shared = GallerySelection()

    /// 选中集合。空 = 未选；1 张 = 单选；多张 = 批量语义。
    @Published private(set) var selectedIDs: Set<Int64> = []
    /// ⇧ 范围选择的锚点：普通点击 / ⌘点击把锚点移到落点，⇧点击保持不动。
    @Published private(set) var anchorID: Int64?
    /// 主选中：单选时的那张 / 多选时最后操作的那张。
    /// inspector 展示、键盘走格起点、Quick Look 定位都以它为准。
    @Published private(set) var primaryID: Int64?
    /// 待确认删除的截图 ID（展示顺序）。键盘 ⌘⌫、右键菜单、多选面板都写这里，
    /// 由 GalleryGrid 上唯一的 confirmationDialog 消费 —— 确认框只有一套。
    @Published var pendingDeleteIDs: [Int64]?

    var isMultiple: Bool { selectedIDs.count > 1 }

    func isSelected(_ id: Int64?) -> Bool {
        id.map { selectedIDs.contains($0) } ?? false
    }

    /// 单选（清空集合）。定位类场景（时间线 / 相似 / 开窗定位 / Quick Look 翻页）
    /// 语义 = 清空后单选，全走这里。
    func select(only id: Int64?) {
        selectedIDs = id.map { [$0] } ?? []
        anchorID = id
        primaryID = id
    }

    /// ⌘点击：toggle 该张的选中态，锚点移到落点。
    func toggle(_ id: Int64) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
            if primaryID == id { primaryID = selectedIDs.first }
        } else {
            selectedIDs.insert(id)
            primaryID = id
        }
        anchorID = id
    }

    /// ⇧点击 / ⇧方向键：选中锚点到目标的**全局顺序**区间（跨分组连续）。
    /// `orderedIDs` 是当前列表的展示顺序；锚点失效时退化为单选。
    func selectRange(to id: Int64, in orderedIDs: [Int64]) {
        guard let anchorID,
              let a = orderedIDs.firstIndex(of: anchorID),
              let b = orderedIDs.firstIndex(of: id)
        else {
            select(only: id)
            return
        }
        selectedIDs = Set(orderedIDs[min(a, b)...max(a, b)])
        primaryID = id
    }

    /// ⌘A：全选当前列表。主选中还在列表里就不跳。
    func selectAll(_ orderedIDs: [Int64]) {
        guard !orderedIDs.isEmpty else { return }
        selectedIDs = Set(orderedIDs)
        anchorID = orderedIDs.first
        if primaryID.map({ selectedIDs.contains($0) }) != true {
            primaryID = orderedIDs.last
        }
    }

    /// Esc：多选收拢回主选中那一张。
    func collapseToPrimary() {
        select(only: primaryID ?? selectedIDs.first)
    }
}

// MARK: - 三栏布局：侧边栏（筛选） / 网格 / 详情
//
// 布局参考 Snagit Library：左侧按 分类 / 应用 导航（带计数和真实 App 图标），
// 中间大缩略图网格 + 底部缩放条，右侧详情。NavigationSplitView 自带侧边栏
// 毛玻璃材质和折叠行为，搜索框走 .searchable 进窗口工具栏。

struct GalleryView: View {

    @ObservedObject private var store = ShotStore.shared
    @ObservedObject private var selection = GallerySelection.shared
    // 语义模式切换只在「开关已开 + 模型已就绪」时出现，所以要订阅这两个。
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var modelStore = CLIPModelStore.shared

    /// 网格列的稳定宽度（外层量取，不受常驻滚动条挤压），列数由它算。
    @State private var gridWidth: CGFloat = 900

    /// 详情栏（inspector）开关，跨启动记住。
    @AppStorage("galleryInspectorShown") private var showInspector = true

    private var semanticAvailable: Bool {
        settings.semanticSearch && modelStore.isReady
    }

    private var selectedShot: Shot? {
        // 语义结果可能不在常规列表（最近 500 张）里，两边都找。
        store.displayShots.first { $0.id == selection.primaryID }
            ?? store.shots.first { $0.id == selection.primaryID }
    }

    /// 多选时按展示顺序解析出的截图（选中集合里可能残留已删除的 ID，以解析结果为准）。
    private var multiSelectedShots: [Shot] {
        guard selection.isMultiple else { return [] }
        var picked = store.displayShots.filter { selection.isSelected($0.id) }
        let seen = Set(picked.compactMap(\.id))
        picked += store.shots.filter { shot in
            guard let id = shot.id else { return false }
            return selection.selectedIDs.contains(id) && !seen.contains(id)
        }
        return picked
    }

    var body: some View {
        // 两栏（侧边栏 + 网格）+ 可开关的 inspector 详情栏 ——
        // 详情从 NavigationSplitView 的 detail 列挪出来，换取标准的
        // 「随时收起给网格让路」行为和系统自带的材质/分隔线。
        NavigationSplitView {
            GallerySidebar()
                .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 280)
        } detail: {
            GalleryGrid(width: gridWidth)
                .background(gridWidthReader)
        }
        .inspector(isPresented: $showInspector) {
            inspectorPane
                .inspectorColumnWidth(min: 260, ideal: 300)
        }
        .searchable(
            text: $store.searchText,
            placement: .toolbar,
            prompt: store.semanticMode
                ? "描述画面内容，回车搜索（英文效果最好）"
                : "搜 App、标题、网址或截图里的字"
        )
        .onChange(of: store.searchText) { _, newValue in
            if store.semanticMode {
                // 语义搜索按回车触发；清空输入即恢复常规列表。
                if newValue.trimmingCharacters(in: .whitespaces).isEmpty {
                    store.clearSemanticResults()
                }
            } else {
                store.reload()
            }
        }
        .onSubmit(of: .search) {
            guard store.semanticMode else { return }
            Task { await store.runSemanticSearch() }
        }
        .toolbar {
            if semanticAvailable {
                ToolbarItem(placement: .primaryAction) {
                    Picker("搜索模式", selection: $store.semanticMode) {
                        Text("精确").tag(false)
                        Text("语义").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .help("精确：全文匹配文字与元数据；语义：用自然语言描述画面，按回车搜索")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showInspector.toggle()
                } label: {
                    Label("详情", systemImage: "sidebar.trailing")
                }
                .help(showInspector ? "隐藏详情栏" : "显示详情栏")
            }
        }
        .onChange(of: store.semanticMode) { _, semantic in
            if !semantic { store.clearSemanticResults() }
        }
        .frame(minWidth: 1000, minHeight: 600)
    }

    @ViewBuilder
    private var inspectorPane: some View {
        let multi = multiSelectedShots
        if multi.count > 1 {
            MultiSelectionPane(shots: multi)
        } else if let shot = selectedShot ?? multi.first {
            ShotDetailPane(shot: shot)
        } else {
            ContentUnavailableView(
                "未选择截图",
                systemImage: "photo.on.rectangle",
                description: Text("在网格中选择一张截图查看详情")
            )
        }
    }

    /// 把网格列的实际宽度报给键盘导航（上下键 = ±列数，列数从宽度反推）。
    private var gridWidthReader: some View {
        GeometryReader { proxy in
            Color.clear
                .onChange(of: proxy.size.width, initial: true) { _, width in
                    GalleryKeyboard.shared.gridWidth = width
                    gridWidth = width
                }
        }
    }
}

// MARK: - 侧边栏

private struct GallerySidebar: View {

    @ObservedObject private var store = ShotStore.shared

    @State private var categories: [(name: String, count: Int)] = []
    @State private var tags: [(name: String, count: Int)] = []
    @State private var apps: [(name: String, bundleID: String?, count: Int)] = []
    @State private var total = 0
    /// 应用组超过 8 个时默认只显示前 5 个，点「显示全部」再展开。
    @State private var appsExpanded = false
    /// 右键「重命名」弹窗的目标标签，非 nil 即弹窗。
    @State private var renamingTag: String?
    @State private var renameText = ""
    /// 右键「删除」确认的目标标签。
    @State private var deletingTag: String?

    /// 应用组是否需要折叠（8 个以内没必要）。
    private var appsCollapsible: Bool { apps.count > 8 }

    private var visibleApps: [(name: String, bundleID: String?, count: Int)] {
        appsCollapsible && !appsExpanded ? Array(apps.prefix(5)) : apps
    }

    var body: some View {
        List(selection: filterBinding) {
            Section("资料库") {
                Label("全部截图", systemImage: "square.grid.2x2")
                    .badge(total)
                    .tag(ShotStore.GalleryFilter.all)
                Label {
                    Text("收藏")
                } icon: {
                    Image(systemName: "star")
                        .foregroundStyle(.yellow)
                }
                .badge(store.favoriteCount())
                .tag(ShotStore.GalleryFilter.favorites)
            }

            if !categories.isEmpty {
                Section("分类") {
                    ForEach(categories, id: \.name) { category in
                        HStack(spacing: DS.s2) {
                            Circle()
                                .fill(DS.categoryColor(category.name))
                                .frame(width: 8, height: 8)
                            Label(category.name, systemImage: icon(forCategory: category.name))
                        }
                        .badge(category.count)
                        .tag(ShotStore.GalleryFilter.category(category.name))
                    }
                }
            }

            // 用户自己的组织方式排在自动分类后面；一个标签都没有时整区不出现。
            if !tags.isEmpty {
                Section("标签") {
                    ForEach(tags, id: \.name) { tag in
                        Label(tag.name, systemImage: "tag")
                            .badge(tag.count)
                            .tag(ShotStore.GalleryFilter.tag(tag.name))
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

            if !apps.isEmpty {
                Section("应用") {
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
                            withAnimation { appsExpanded.toggle() }
                        } label: {
                            Label(
                                appsExpanded ? "收起" : "显示全部（\(apps.count) 个）",
                                systemImage: appsExpanded ? "chevron.up" : "chevron.down"
                            )
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .selectionDisabled()
                    }
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
            Button("重命名") { store.renameTag(tag, to: renameText) }
            Button("取消", role: .cancel) {}
        } message: { tag in
            Text("所有打了「\(tag)」的截图都会改用新名字。")
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

    private func refresh() {
        total = store.totalCount
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
            icon = AppIconCache.shared.icon(for: bundleID)
        }
    }
}

@MainActor
private final class AppIconCache {
    static let shared = AppIconCache()
    private var cache: [String: NSImage] = [:]

    func icon(for bundleID: String?) -> NSImage? {
        guard let bundleID else { return nil }
        if let cached = cache[bundleID] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return nil
        }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 16, height: 16)
        cache[bundleID] = icon
        return icon
    }
}

// MARK: - 网格

/// 一个时间段的截图。分组在 shots 变化时算一次，不在 body 里逐帧分组。
private struct ShotSection: Identifiable {
    let id: String
    let title: String
    let shots: [Shot]

    /// 按拍摄时间分成 今天 / 昨天 / 本周 / 本月 / 更早，空段不出现。
    /// shots 已按时间降序，段内顺序自然保持。
    static func group(_ shots: [Shot], calendar: Calendar = .current) -> [ShotSection] {
        let now = Date()
        var buckets: [String: [Shot]] = [:]
        for shot in shots {
            let date = shot.capturedAt
            let key: String
            if calendar.isDateInToday(date) {
                key = "今天"
            } else if calendar.isDateInYesterday(date) {
                key = "昨天"
            } else if calendar.isDate(date, equalTo: now, toGranularity: .weekOfYear) {
                key = "本周"
            } else if calendar.isDate(date, equalTo: now, toGranularity: .month) {
                key = "本月"
            } else {
                key = "更早"
            }
            buckets[key, default: []].append(shot)
        }
        return ["今天", "昨天", "本周", "本月", "更早"].compactMap { title in
            buckets[title].map { ShotSection(id: title, title: title, shots: $0) }
        }
    }
}

private struct GalleryGrid: View {

    /// 外层（不受滚动条出没影响的）可用宽度，列数由它显式算出。
    let width: CGFloat

    @ObservedObject private var store = ShotStore.shared
    @ObservedObject private var selection = GallerySelection.shared

    /// 缩略图基准宽度，底部滑杆控制，跨启动记住。
    @AppStorage("galleryZoom") private var zoom = 200.0

    /// 按时间段分好组的结果，随 store.shots 变化重算一次。
    @State private var sections: [ShotSection] = []
    /// shotID → 分类名。分组时一条 IN 查询批量拉好，卡片只收结果，保持不订阅 store。
    @State private var categoriesByShot: [Int64: String] = [:]
    /// 修订数 > 1（真的标注过）的截图 ID，卡片右下角角标用。同样批量查好下发。
    @State private var annotatedIDs: Set<Int64> = []
    /// 右键菜单打开的时间线 / 相似 sheet。
    @State private var timelineShot: Shot?
    @State private var similarShot: Shot?

    /// 列布局用**固定列宽**，由外层稳定宽度显式算出，绝不用 .adaptive ——
    /// 接实体鼠标时 macOS 显示常驻滚动条：内容超高 → 滚动条挤窄内容区 →
    /// adaptive 重排少一列 → 内容变矮 → 滚动条消失 → 变宽 → 翻回来……
    /// 自持振荡，表现为尾部卡片无输入也一直闪。列数只看外层宽度就稳了。
    private func fixedColumns(for width: CGFloat) -> (items: [GridItem], count: Int) {
        var count = max(1, Int((width - 2 * DS.s4 + DS.s4) / (zoom + DS.s4)))
        // 给常驻滚动条预留：列宽按可用宽扣除 16pt 计算，列数不受它出没影响。
        let usable = width - 2 * DS.s4 - 16 - CGFloat(count - 1) * DS.s4
        if usable < CGFloat(count) * zoom * 0.6 { count = max(1, count - 1) }
        let itemWidth = max(80, (width - 2 * DS.s4 - 16 - CGFloat(count - 1) * DS.s4) / CGFloat(count))
        return (
            Array(repeating: GridItem(.fixed(itemWidth), spacing: DS.s4), count: count),
            count
        )
    }

    /// 网格内容的重算触发器：模式切换或数据变化都要重新分组。
    private struct GridKey: Equatable {
        let semanticMode: Bool
        let shots: [Shot]
    }

    var body: some View {
        VStack(spacing: 0) {
            if store.displayShots.isEmpty {
                emptyState
            } else {
                grid
            }

            Divider()
            bottomBar
        }
        .background(.background)
        .task(id: GridKey(semanticMode: store.semanticMode, shots: store.displayShots)) {
            // 语义结果本身就是排序（相似度降序），按时间分组会打乱它 —— 单段平铺。
            if store.semanticMode, let results = store.semanticResults {
                sections = results.isEmpty
                    ? []
                    : [ShotSection(id: "语义", title: "按相似度排序", shots: results)]
            } else {
                sections = ShotSection.group(store.displayShots)
            }
            // 分组的同时把卡片要的派生信息批量查好：分类胶囊 + 标注角标。
            let ids = store.displayShots.compactMap(\.id)
            categoriesByShot = store.attributeTexts(key: AttributeKey.category, shotIDs: ids)
            annotatedIDs = store.annotatedShotIDs(among: ids)
        }
        .sheet(item: $timelineShot) { TimelineSheet(shot: $0) }
        .sheet(item: $similarShot) { SimilarShotsSheet(shot: $0) }
        // 删除确认只有这一套：键盘 ⌘⌫、右键（单张 / 批量）、多选面板
        // 都通过 selection.pendingDeleteIDs 驱动到这里。删除不可撤销，必须过确认。
        .confirmationDialog(
            Text(deleteDialogTitle),
            isPresented: Binding(
                get: { selection.pendingDeleteIDs != nil },
                set: { if !$0 { selection.pendingDeleteIDs = nil } }
            ),
            presenting: selection.pendingDeleteIDs
        ) { ids in
            Button(ids.count == 1 ? "删除" : "删除 \(ids.count) 张", role: .destructive) {
                deleteShots(ids)
            }
            Button("取消", role: .cancel) {}
        } message: { ids in
            Text(ids.count == 1
                ? "原图和全部标注修订会一并删除，无法撤销。"
                : "这 \(ids.count) 张的原图和全部标注修订会一并删除，无法撤销。")
        }
    }

    private var deleteDialogTitle: String {
        let count = selection.pendingDeleteIDs?.count ?? 0
        return count > 1 ? "删除 \(count) 张截图？" : "删除这张截图？"
    }

    /// 真正执行删除。之后把选中顺移到相邻一张，键盘导航不断档。
    private func deleteShots(_ ids: [Int64]) {
        let idSet = Set(ids)
        let display = store.displayShots
        let anchorIndex = display.firstIndex { $0.id.map(idSet.contains) ?? false }
        // 语义结果可能不在常规列表里，两边找齐（去重）再删。
        var seen = Set<Int64>()
        let targets = (display + store.shots).filter { shot in
            guard let id = shot.id, idSet.contains(id), !seen.contains(id) else { return false }
            seen.insert(id)
            return true
        }
        for shot in targets { store.delete(shot) }
        let remaining = store.displayShots
        if let anchorIndex, !remaining.isEmpty {
            selection.select(only: remaining[min(anchorIndex, remaining.count - 1)].id)
        } else {
            selection.select(only: nil)
        }
    }

    private var grid: some View {
        let layout = fixedColumns(for: width)
        return ScrollViewReader { proxy in
            ScrollView {
                // 单层 LazyVGrid + Section：嵌套懒容器（LazyVStack>LazyVGrid）
                // 在内容尾部有已知的重排抖动，扁平化后吸顶头由网格自己管。
                LazyVGrid(
                    columns: layout.items,
                    alignment: .leading,
                    spacing: DS.s4,
                    pinnedViews: [.sectionHeaders]
                ) {
                    ForEach(sections) { section in
                        Section {
                            ForEach(section.shots) { shot in
                                card(for: shot)
                            }
                        } header: {
                            sectionHeader(for: section)
                        }
                    }
                }
                .padding(.horizontal, DS.s4)
                .padding(.bottom, DS.s3)
            }
            .onChange(of: layout.count, initial: true) { _, count in
                GalleryKeyboard.shared.columnCountOverride = count
            }
            // 时间线 / 相似 sheet 里选中某张后要能真的滚到它。
            // anchor 用 nil = 最小滚动：目标已可见就一动不动 ——
            // 普通点击选中不能抢走用户的滚动位置（用 .center 会每点一下拽到中间）。
            .onChange(of: selection.primaryID) { _, newID in
                guard let newID else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(newID, anchor: nil)
                }
            }
        }
    }

    /// 吸顶分组标题：「今天 · 12」，垫 .bar 材质盖住滚过的卡片。
    private func sectionHeader(for section: ShotSection) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.s2) {
            Text(section.title)
                .font(.title3.weight(.semibold))
            Text("· \(section.shots.count)")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, DS.s4)
        .padding(.vertical, DS.s2)
        .background(.bar)
    }

    private func card(for shot: Shot) -> some View {
        ShotCard(
            shot: shot,
            height: zoom * 0.68,
            isSelected: selection.isSelected(shot.id),
            isFavorite: shot.id.map(store.isFavorite) ?? false,
            category: shot.id.flatMap { categoriesByShot[$0] },
            isAnnotated: shot.id.map(annotatedIDs.contains) ?? false,
            onToggleFavorite: { store.toggleFavorite(shot) }
        )
        .id(shot.id)
        .onTapGesture { handleTap(shot) }
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                // 带修饰键的双击只是两次修饰点击（toggle / 范围），不进编辑器。
                guard currentModifiers().isEmpty else { return }
                EditorWindowController.open(shot)
            }
        )
        .draggable(dragFile(for: shot))
        .contextMenu {
            // ⚠️ 这个 ViewBuilder 会在**普通渲染时**被 SwiftUI 求值，不是右键才跑 ——
            // 在这里写任何状态（哪怕 async）都会形成「渲染→改选中→重渲染」的自激振荡
            // （曾经的尾部卡片 20Hz 闪烁事故，选中乒乓 4 万次/分钟）。只准纯读。
            // 右键未选中的卡不再抢选中（Finder 的预选行为放弃）：菜单项本就绑定该 shot。
            if selection.isMultiple && selection.isSelected(shot.id) {
                batchContextMenu()
            } else {
                contextMenu(for: shot)
            }
        } preview: {
            CachedImage(url: store.thumbnailURL(for: shot), key: shot.sha256)
                .frame(maxWidth: 480, maxHeight: 360)
        }
    }

    /// 点击 = 单选；⌘点击 = toggle；⇧点击 = 锚点到落点的全局顺序区间。
    private func handleTap(_ shot: Shot) {
        guard let id = shot.id else { return }
        let flags = currentModifiers()
        if flags.contains(.command) {
            selection.toggle(id)
        } else if flags.contains(.shift) {
            selection.selectRange(to: id, in: store.displayShots.compactMap(\.id))
        } else {
            selection.select(only: id)
        }
    }

    /// SwiftUI 的 TapGesture 不带修饰键信息，从触发点击的 NSEvent 上取。
    private func currentModifiers() -> NSEvent.ModifierFlags {
        NSApp.currentEvent?.modifierFlags.intersection(.deviceIndependentFlagsMask) ?? []
    }

    /// 多选右键的批量菜单：标题带张数，动作与多选详情栏共用一套实现。
    @ViewBuilder
    private func batchContextMenu() -> some View {
        let shots = GalleryBatch.selectedShots()
        let count = shots.count
        Button(GalleryBatch.allFavorited(shots) ? "取消收藏 \(count) 张" : "收藏 \(count) 张") {
            GalleryBatch.toggleFavorites(shots)
        }
        Button("导出 \(count) 张…") {
            Task { _ = await GalleryBatch.exportAll(shots) }
        }
        Divider()
        Button("删除 \(count) 张截图…", role: .destructive) {
            selection.pendingDeleteIDs = shots.compactMap(\.id)
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(emptyTitle, systemImage: emptyIcon)
        } description: {
            Text(emptyDescription)
        } actions: {
            if hasActiveFilter {
                Button("清除筛选") { clearFilters() }
            } else {
                Button("开始截图") { CaptureCoordinator.shared.begin() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 空态是「筛出来的空」还是「真的一张都没有」——决定给哪个按钮。
    private var hasActiveFilter: Bool {
        !store.searchText.isEmpty
            || store.filter != .all
            || (store.semanticMode && store.semanticResults != nil)
    }

    private func clearFilters() {
        store.searchText = ""
        store.filter = .all
        store.clearSemanticResults()
        store.reload()
    }

    private var emptyTitle: String {
        if store.semanticMode && store.semanticResults != nil { return "没有语义匹配的结果" }
        return store.searchText.isEmpty ? "还没有截图" : "没有匹配的结果"
    }

    private var emptyIcon: String {
        if store.semanticMode && store.semanticResults != nil { return "sparkle.magnifyingglass" }
        return store.searchText.isEmpty ? "photo.on.rectangle.angled" : "magnifyingglass"
    }

    private var emptyDescription: String {
        if store.semanticMode && store.semanticResults != nil {
            return "截图可能还没完成向量分析，或换种描述再试（英文效果最好）"
        }
        return store.searchText.isEmpty ? "按 ⌃⌘A 开始截图" : "换个关键词，或清除侧边栏筛选"
    }

    private var bottomBar: some View {
        HStack(spacing: DS.s3) {
            if store.isSemanticSearching {
                ProgressView().controlSize(.mini)
                Text("语义搜索中…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if store.semanticMode, store.semanticResults != nil {
                Text("语义搜索：最相关的 \(store.displayShots.count) 张")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("\(store.displayShots.count) 张截图")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "square.grid.3x3")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Slider(value: $zoom, in: 140...320)
                .frame(width: 140)
                .controlSize(.small)
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, DS.s3)
        .padding(.vertical, DS.s2)
        .background(.bar)
    }

    @ViewBuilder
    private func contextMenu(for shot: Shot) -> some View {
        Button(shot.id.map(store.isFavorite) ?? false ? "取消收藏" : "收藏") {
            store.toggleFavorite(shot)
        }
        Button("编辑标注") { EditorWindowController.open(shot) }
        Button("钉在桌面") { pin(shot) }
        Button("复制图片") { copy(shot) }
        Divider()
        Button("相似截图") { similarShot = shot }
        Button("时间线") { timelineShot = shot }
        Divider()
        Button("出处") { openSource(of: shot) }
            .disabled(shot.sourceURL == nil && shot.appBundleID == nil)
        Button("在访达中显示") {
            SystemNavigator.revealInFinder(store.originalURL(for: shot))
        }
        Divider()
        Button("导出…") { export(shot) }
        if !AppSettings.shared.uploadEndpoint.isEmpty {
            Button("上传并复制链接") { upload(shot) }
        }
        Button("复制 Bug 报告") {
            Clipboard.copy(text: BugReport.markdown(
                shot: shot,
                pixelWidth: shot.pixelWidth,
                pixelHeight: shot.pixelHeight
            ))
        }
        Divider()
        Button("删除…", role: .destructive) {
            selection.pendingDeleteIDs = shot.id.map { [$0] }
        }
    }

    /// 含最新标注的成品图。导出 / 上传 / 拖出共用一个口径 —— 和暂存栏、详情页一致。
    private func renderedImage(for shot: Shot) -> CGImage? {
        guard let base = store.originalImage(for: shot) else { return nil }
        return LayerRenderer.render(
            base: base,
            layers: store.latestRevision(for: shot)?.imageLayers ?? Layers()
        )
    }

    private func export(_ shot: Shot) {
        guard let rendered = renderedImage(for: shot) else { return }
        _ = try? ImageExporter.exportWithPanel(
            rendered,
            suggestedName: ImageExporter.suggestedName(for: shot)
        )
    }

    /// 上传到自定义图床，链接进剪贴板。配置读「设置 → 上传」，和截图动作同一套。
    private func upload(_ shot: Shot) {
        guard let rendered = renderedImage(for: shot),
              let png = ImageCodec.pngData(from: rendered) else { return }
        let settings = AppSettings.shared
        let config = UploadConfig(
            endpoint: settings.uploadEndpoint,
            fieldName: settings.uploadFieldName,
            headersText: settings.uploadHeaders,
            responsePath: settings.uploadResponsePath
        )
        let filename = ImageExporter.suggestedName(for: shot)
        Task {
            do {
                let link = try await ImageUploader.upload(png: png, filename: filename, config: config)
                Clipboard.copy(text: settings.uploadLinkFormat.format(link))
                NSLog("[MacShot] 图库上传成功，链接已复制: \(link)")
            } catch {
                NSLog("[MacShot] 图库上传失败: \(error)")
            }
        }
    }

    /// 拖出卡片的载荷。**必须是廉价构造**：`.draggable` 的载荷在 body 里
    /// 逐卡片急切求值，任何重活（读原图/渲染/写盘）放在这里都会把主线程打满 ——
    /// 表现就是「图库滚不动、点击丢失」。渲染推迟到真正拖放时的传输闭包里做。
    private func dragFile(for shot: Shot) -> ShotDragFile {
        ShotDragFile(shot: shot)
    }

    private func pin(_ shot: Shot) {
        guard let base = store.originalImage(for: shot) else { return }
        PinWindowController.pin(
            base: base,
            layers: store.latestRevision(for: shot)?.imageLayers ?? Layers(),
            shot: shot,
            at: .zero
        )
    }

    private func copy(_ shot: Shot) {
        guard let base = store.originalImage(for: shot) else { return }
        let layers = store.latestRevision(for: shot)?.imageLayers ?? Layers()
        Clipboard.copy(LayerRenderer.render(base: base, layers: layers))
    }

    /// 回到出处：优先开网址（默认浏览器），否则激活来源 App。
    private func openSource(of shot: Shot) {
        if let source = shot.sourceURL, let url = URL(string: source) {
            SystemNavigator.open(url: url)
        } else if let bundleID = shot.appBundleID {
            SystemNavigator.activateApp(bundleID: bundleID)
        }
    }
}

// MARK: - 批量动作

/// 批量动作的共用实现：右键批量菜单和多选详情栏都走这里，行为只有一份。
@MainActor
private enum GalleryBatch {

    /// 按展示顺序解析当前选中集合。语义结果可能不在常规列表里，两边找齐（去重）。
    static func selectedShots() -> [Shot] {
        let selection = GallerySelection.shared
        let store = ShotStore.shared
        var picked = store.displayShots.filter { selection.isSelected($0.id) }
        let seen = Set(picked.compactMap(\.id))
        picked += store.shots.filter { shot in
            guard let id = shot.id else { return false }
            return selection.selectedIDs.contains(id) && !seen.contains(id)
        }
        return picked
    }

    static func allFavorited(_ shots: [Shot]) -> Bool {
        !shots.isEmpty && shots.allSatisfy { $0.id.map(ShotStore.shared.isFavorite) ?? false }
    }

    /// 全部收藏 / 全部取消收藏：已经是目标状态的跳过，动作幂等。
    static func toggleFavorites(_ shots: [Shot]) {
        let store = ShotStore.shared
        let targetFavorited = !allFavorited(shots)
        for shot in shots {
            guard let id = shot.id, store.isFavorite(shotID: id) != targetFavorited else { continue }
            store.toggleFavorite(shot)
        }
    }

    /// 后台渲染一张成品要的全部材料，主线程收集好再整体下后台。
    private struct ExportJob {
        let url: URL
        let layers: Layers<ImageSpace>
        let name: String
    }

    /// 批量导出：NSOpenPanel 选目录，逐张渲染成品（含最新标注）按文件名模板写入，
    /// 重名由 ImageExporter.writePNG 自动加 -2 / -3 … 序号。返回成功张数（取消 = 0）。
    static func exportAll(_ shots: [Shot]) async -> Int {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "导出到此处"
        panel.message = "选择 \(shots.count) 张截图的导出目录"
        panel.directoryURL = FileManager.default
            .urls(for: .desktopDirectory, in: .userDomainMask).first

        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let directory = panel.url else { return 0 }

        let store = ShotStore.shared
        let jobs = shots.map { shot in
            ExportJob(
                url: store.originalURL(for: shot),
                layers: store.latestRevision(for: shot)?.imageLayers ?? Layers(),
                name: ImageExporter.suggestedName(for: shot)
            )
        }
        // 解码 / 渲染 / 编码 / 写盘都是重活，整体放后台，主线程不卡。
        return await Task.detached(priority: .userInitiated) {
            var exported = 0
            for job in jobs {
                guard let base = ImageCodec.load(from: job.url) else { continue }
                let rendered = LayerRenderer.render(base: base, layers: job.layers)
                guard let png = ImageCodec.pngData(from: rendered) else { continue }
                if (try? ImageExporter.writePNG(png, into: directory, preferredName: job.name)) != nil {
                    exported += 1
                }
            }
            return exported
        }.value
    }
}

// MARK: - 卡片

/// 拖出卡片的载荷。构造只是拷一个 Shot 值 —— 渲染含标注的成品 PNG
/// 发生在**接收方真正收文件时**（FileRepresentation 的导出闭包），
/// 目录复用暂存栏的拖拽临时目录，下次启动统一清理；渲染失败退回原图路径。
private struct ShotDragFile: Transferable {
    let shot: Shot

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .png) { file in
            let url = await MainActor.run { file.writeRenderedPNG() }
            return SentTransferredFile(url, allowAccessingOriginalFile: true)
        }
    }

    /// 重活集中在这：读原图 → 合成最新修订 → 编码 → 写临时文件。
    /// 只在一次真实的拖放里执行一次。
    @MainActor
    fileprivate func writeRenderedPNG() -> URL {
        let store = ShotStore.shared
        let fallback = store.originalURL(for: shot)

        guard let base = store.originalImage(for: shot) else { return fallback }
        let rendered = LayerRenderer.render(
            base: base,
            layers: store.latestRevision(for: shot)?.imageLayers ?? Layers()
        )
        guard let png = ImageCodec.pngData(from: rendered) else { return fallback }

        let dir = ShelfController.dragFileDirectory
            .appendingPathComponent(shot.sha256, isDirectory: true)
        let url = dir.appendingPathComponent(ImageExporter.suggestedName(for: shot))
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try png.write(to: url, options: .atomic)
            return url
        } catch {
            return fallback
        }
    }
}

private struct ShotCard: View {
    let shot: Shot
    let height: CGFloat
    let isSelected: Bool
    /// 收藏态由父级（已订阅 store 的 GalleryGrid）传入，卡片本身保持不订阅。
    let isFavorite: Bool
    /// 分类 / 标注角标同样由父级批量查好传入。
    let category: String?
    let isAnnotated: Bool
    let onToggleFavorite: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovering = false
    /// 悬停 0.3s 后才浮出尺寸条 —— 快速扫过不打扰。
    @State private var showsDimensions = false

    // 刻意不用 @ObservedObject 订阅 store —— 只需要一个文件路径，
    // 订阅了会导致任何 store 变化都重建全部缩略图。
    private var thumbnailURL: URL { ShotStore.shared.thumbnailURL(for: shot) }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.s2) {
            thumbnail
            caption
        }
        .onHover { isHovering = $0 }
        .task(id: isHovering) {
            guard isHovering else {
                showsDimensions = false
                return
            }
            try? await Task.sleep(for: .seconds(0.3))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.15)) { showsDimensions = true }
        }
    }

    private var thumbnail: some View {
        ZStack {
            RoundedRectangle(cornerRadius: DS.radiusCard)
                .fill(.quaternary.opacity(0.5))
            CachedImage(url: thumbnailURL, key: shot.sha256)
                .clipShape(RoundedRectangle(cornerRadius: DS.radiusCard))
        }
        .frame(height: height)
        // 尺寸浮条盖在底边，先叠再裁 —— 让浮条跟着卡片圆角走。
        .overlay(alignment: .bottom) { dimensionBar }
        .clipShape(RoundedRectangle(cornerRadius: DS.radiusCard))
        .overlay {
            // 深色模式悬停不加阴影（黑底上看不见），改为整体提亮一档。
            if colorScheme == .dark && isHovering {
                RoundedRectangle(cornerRadius: DS.radiusCard)
                    .fill(Color.white.opacity(0.05))
                    .allowsHitTesting(false)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: DS.radiusCard)
                .strokeBorder(Color.primary.opacity(strokeOpacity), lineWidth: 1)
        }
        .overlay(alignment: .bottomLeading) { categoryBadge }
        .overlay(alignment: .bottomTrailing) { annotationBadge }
        .overlay(alignment: .topTrailing) { favoriteButton }
        // 选中描边外扩，不压缩略图本身。
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: DS.radiusCard + 3)
                    .strokeBorder(Color.accentColor, lineWidth: 2.5)
                    .padding(-DS.s1)
            }
        }
        .shadow(
            color: shadowColor,
            radius: isHovering ? 7 : 3,
            y: 2
        )
        .scaleEffect(isHovering && !isSelected ? 1.015 : 1)
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .animation(.easeOut(duration: 0.12), value: isSelected)
    }

    /// 描边随深浅色分流：深色描边是唯一的悬停反馈来源之一，悬停升到 0.18；
    /// 浅色有阴影帮忙，维持原来的 0.25。
    private var strokeOpacity: Double {
        if colorScheme == .dark {
            return isHovering ? 0.18 : 0.08
        }
        return isHovering ? 0.25 : 0.08
    }

    /// 浅色小阴影撑层次；深色去阴影（层次交给描边 + 提亮）。
    private var shadowColor: Color {
        colorScheme == .dark
            ? .clear
            : .black.opacity(isHovering || isSelected ? 0.16 : 0.08)
    }

    /// 悬停浮条：像素尺寸。半透明材质垫底，从底边浮入。
    @ViewBuilder
    private var dimensionBar: some View {
        if showsDimensions {
            Text("\(shot.pixelWidth) × \(shot.pixelHeight)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.vertical, DS.s1)
                .frame(maxWidth: .infinity)
                .background(.ultraThinMaterial)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    /// 左下角分类胶囊。尺寸浮条出现时让位，避免底边挤成一团。
    @ViewBuilder
    private var categoryBadge: some View {
        if let category, !showsDimensions {
            Text(category)
                .font(.caption2)
                .padding(.horizontal, DS.s2)
                .padding(.vertical, 2)
                .background(.thinMaterial, in: Capsule())
                .padding(DS.s2)
                .transition(.opacity)
        }
    }

    /// 右下角标注角标：修订数 > 1（真的画过）才出现。
    @ViewBuilder
    private var annotationBadge: some View {
        if isAnnotated && !showsDimensions {
            Image(systemName: "pencil")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(DS.s1)
                .background(.thinMaterial, in: Circle())
                .padding(DS.s2)
                .transition(.opacity)
                .help("已标注")
        }
    }

    /// 悬停浮出星形按钮；已收藏则常显实心黄星。材质圆底 + ≥32pt 热区。
    @ViewBuilder
    private var favoriteButton: some View {
        if isHovering || isFavorite {
            Button(action: onToggleFavorite) {
                ZStack {
                    Circle()
                        .fill(.ultraThinMaterial)
                        .frame(width: 24, height: 24)
                    Image(systemName: isFavorite ? "star.fill" : "star")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(isFavorite ? .yellow : .primary)
                        .symbolEffect(.bounce, value: isFavorite)
                }
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(DS.s1)
            .help(isFavorite ? "取消收藏" : "收藏")
        }
    }

    private var caption: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(shot.appName ?? "未知 App")
                .font(.caption.weight(.medium))
                .lineLimit(1)
            Text(shot.capturedAt, format: .dateTime.month().day().hour().minute())
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 2)
    }
}

// MARK: - 多选详情栏

/// 选中 N>1 张时替换 ShotDetailPane 的批量面板：
/// 「已选 N 张」+ 2×2 缩略图拼贴 + 批量动作（收藏 / 导出 / 删除）。
private struct MultiSelectionPane: View {
    /// 展示顺序的选中截图，由 GalleryView 解析好传入。
    let shots: [Shot]

    // 订阅 store 是为了收藏态实时刷新（批量收藏后按钮文案要翻转）。
    @ObservedObject private var store = ShotStore.shared
    @ObservedObject private var selection = GallerySelection.shared

    /// 最近一次批量导出的结果提示，几秒后自动消失。
    @State private var exportSummary: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.s3) {
                collage
                Text("已选 \(shots.count) 张")
                    .font(.title3.weight(.semibold))
                Text("批量动作作用于全部选中项。按 Esc 回到单选。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                actions
                if let exportSummary {
                    Label(exportSummary, systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.green)
                        .transition(.opacity)
                }
            }
            .padding(DS.s4)
        }
    }

    /// 2×2 拼贴：展示顺序前 4 张，超出的在最后一格盖 +N。
    private var collage: some View {
        let previews = Array(shots.prefix(4))
        return LazyVGrid(
            columns: [
                GridItem(.flexible(), spacing: DS.s2),
                GridItem(.flexible(), spacing: DS.s2)
            ],
            spacing: DS.s2
        ) {
            ForEach(previews) { shot in
                ZStack {
                    RoundedRectangle(cornerRadius: DS.radiusSmall)
                        .fill(.quaternary.opacity(0.5))
                    CachedImage(url: store.thumbnailURL(for: shot), key: shot.sha256)
                        .clipShape(RoundedRectangle(cornerRadius: DS.radiusSmall))
                }
                .frame(height: 76)
                .overlay {
                    if shot.id == previews.last?.id, shots.count > 4 {
                        RoundedRectangle(cornerRadius: DS.radiusSmall)
                            .fill(.black.opacity(0.45))
                        Text("+\(shots.count - 4)")
                            .font(.title3.weight(.bold))
                            .foregroundStyle(.white)
                    }
                }
            }
        }
    }

    private var actions: some View {
        VStack(spacing: DS.s2) {
            let allFavorited = GalleryBatch.allFavorited(shots)
            Button {
                GalleryBatch.toggleFavorites(shots)
            } label: {
                Label(
                    allFavorited ? "取消收藏 \(shots.count) 张" : "全部收藏",
                    systemImage: allFavorited ? "star.slash" : "star"
                )
                .frame(maxWidth: .infinity)
            }

            Button {
                runExport()
            } label: {
                Label("导出 \(shots.count) 张…", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .help("选一个目录，逐张按文件名模板导出成品（含标注），重名自动加序号")

            Button(role: .destructive) {
                selection.pendingDeleteIDs = shots.compactMap(\.id)
            } label: {
                Label("删除 \(shots.count) 张…", systemImage: "trash")
                    .frame(maxWidth: .infinity)
            }
        }
        .buttonStyle(.bordered)
    }

    private func runExport() {
        let targets = shots
        Task {
            let exported = await GalleryBatch.exportAll(targets)
            guard exported > 0 else { return }
            withAnimation {
                exportSummary = exported < targets.count
                    ? "已导出 \(exported)/\(targets.count) 张"
                    : "已导出 \(exported) 张"
            }
            try? await Task.sleep(for: .seconds(4))
            withAnimation { exportSummary = nil }
        }
    }
}

// MARK: - 右侧详情

/// 修订的展示用快照。避免在 body 里反复解 layersJSON。
private struct RevisionSummary: Identifiable {
    let id: Int64
    let version: Int
    let note: String
    let layerCount: Int
    let createdAt: Date
}

private struct ShotDetailPane: View {
    let shot: Shot

    // 订阅 store 是为了收藏态实时刷新；重查询都挂在 task(id:) 上，不受影响。
    @ObservedObject private var store = ShotStore.shared
    @ObservedObject private var selection = GallerySelection.shared

    /// 修订历史只在切换截图 / 关闭编辑器时查一次数据库，不再挂在 body 上。
    @State private var revisions: [RevisionSummary] = []
    /// 派生属性同理，切换截图时查一次。
    @State private var category: String?
    /// 目标是否已有特征指纹。没有就先禁用「相似」——刚截的图可能还在后台分析。
    @State private var hasFeaturePrint = false
    @State private var showingSimilar = false
    /// 同源截图数量（含自己）。切换截图时查一次，少于 2 张禁用时间线入口。
    @State private var relatedCount = 0
    @State private var showingTimeline = false
    /// 敏感内容检测结果（后台异步落库，和指纹一样随 store 刷新重查）。
    @State private var sensitiveRegions: [SensitiveRegion] = []
    /// 是否已打码。加载时按「最新修订的马赛克层是否盖住全部命中区域」判定，
    /// 一键打码完成后直接置真。
    @State private var sensitiveMasked = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.s3) {
                preview
                actions
                if !sensitiveRegions.isEmpty {
                    sensitiveBanner
                }
                sourceCard
                // TagSection 插槽：标签分支（feat/tags）会在来源和识别之间
                // 插入单选详情的标签行。
                recognitionCard
                TagSection(shot: shot)
                historyCard
            }
            .padding(DS.s4)
        }
        .task(id: shot.id) {
            loadRevisions()
            category = shot.id.flatMap { store.attributeText(shotID: $0, key: AttributeKey.category) }
            refreshFeaturePrint()
            refreshSensitiveRegions()
            relatedCount = store.relatedShots(to: shot).count
        }
        // 指纹由后台分析异步补上：store 每次刷新（属性落库会触发 reload）都重查一次。
        // 属性写入不一定改变 shots 数组本身，所以订阅 objectWillChange 而不是 onChange。
        // 单行 LIMIT 1 查询，代价可忽略。
        // 修订列表同理：编辑器已是独立窗口（非模态），保存时机不再有
        // 「sheet 收起」这样的锚点 —— appendRevision 落库会发布变更，这里重查。
        .onReceive(store.objectWillChange) { _ in
            refreshFeaturePrint()
            refreshSensitiveRegions()
            loadRevisions()
        }
        .sheet(isPresented: $showingSimilar) {
            SimilarShotsSheet(shot: shot)
        }
        .sheet(isPresented: $showingTimeline) {
            TimelineSheet(shot: shot)
        }
    }

    private func refreshFeaturePrint() {
        hasFeaturePrint = shot.id.map {
            store.attributePayload(shotID: $0, key: AttributeKey.featurePrint) != nil
        } ?? false
    }

    private func refreshSensitiveRegions() {
        guard let id = shot.id,
              let data = store.attributePayload(shotID: id, key: AttributeKey.sensitiveRegions),
              let regions = try? JSONDecoder().decode([SensitiveRegion].self, from: data),
              !regions.isEmpty
        else {
            sensitiveRegions = []
            sensitiveMasked = false
            return
        }
        sensitiveRegions = regions
        // 已打码 = 最新修订里每个命中区域都被某个马赛克层完整覆盖。
        let pixelates = (store.latestRevision(for: shot)?.layers ?? [])
            .filter { $0.kind == .pixelate }
        sensitiveMasked = regions.allSatisfy { region in
            pixelates.contains { $0.rect.cg.contains(region.rect) }
        }
    }

    /// 按种类汇总的提示文案，如「2 处邮箱、1 处 API 密钥」。
    private var sensitiveSummary: String {
        var order: [String] = []
        var counts: [String: Int] = [:]
        for region in sensitiveRegions {
            if counts[region.kind] == nil { order.append(region.kind) }
            counts[region.kind, default: 0] += 1
        }
        return order.map { "\(counts[$0] ?? 0) 处\($0)" }.joined(separator: "、")
    }

    private var sensitiveBanner: some View {
        VStack(alignment: .leading, spacing: DS.s2) {
            HStack(alignment: .firstTextBaseline, spacing: DS.s2) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("检测到敏感内容：\(sensitiveSummary)")
                    .font(.caption.weight(.semibold))
            }
            Text(sensitiveRegions.map(\.preview).joined(separator: " · "))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(3)
            if sensitiveMasked {
                Label("已打码", systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.green)
            } else {
                Button {
                    maskSensitiveRegions()
                } label: {
                    Label("一键打码", systemImage: "squareshape.split.3x3")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(DS.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.radiusCard)
                .fill(Color.yellow.opacity(0.18))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.radiusCard)
                .strokeBorder(Color.yellow.opacity(0.5), lineWidth: 1)
        )
    }

    /// 一键打码：每个命中区域外扩 4px 生成一个马赛克层，
    /// 追加为**新修订**（非破坏，历史可回溯，随时能回到打码前）。
    private func maskSensitiveRegions() {
        let existing = store.latestRevision(for: shot)?.imageLayers ?? Layers()
        var layers = existing
        let bounds = CGRect(
            x: 0, y: 0,
            width: CGFloat(shot.pixelWidth), height: CGFloat(shot.pixelHeight)
        )
        for region in sensitiveRegions {
            let rect = region.rect.insetBy(dx: -4, dy: -4).intersection(bounds)
            guard !rect.isNull, !rect.isEmpty else { continue }
            layers.append(Layer(kind: .pixelate, rect: LRect(rect)))
        }
        guard store.appendRevision(shot: shot, layers: layers, note: "自动脱敏") != nil else { return }
        sensitiveMasked = true
        loadRevisions()
    }

    private func loadRevisions() {
        revisions = store.revisions(for: shot).enumerated().map { index, rev in
            RevisionSummary(
                id: rev.id ?? Int64(index),
                version: index + 1,
                note: rev.note ?? "编辑",
                layerCount: rev.layers.count,
                createdAt: rev.createdAt
            )
        }
    }

    private var preview: some View {
        CachedImage(url: store.thumbnailURL(for: shot), key: shot.sha256)
            .clipShape(RoundedRectangle(cornerRadius: DS.radiusCard))
            .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
            .contentShape(Rectangle())
            .onTapGesture { QuickLookController.shared.present() }
            .help("点击（或按空格）用 Quick Look 预览原图")
    }

    /// 动作区一行放完：「编辑」主按钮 + 收藏/钉图/导出 icon-only，
    /// 低频动作（出处/相似/时间线/Bug 报告/上传）收进「更多」菜单。
    private var actions: some View {
        HStack(spacing: DS.s2) {
            Button {
                EditorWindowController.open(shot)
            } label: {
                Label("编辑", systemImage: "pencil.tip.crop.circle")
            }
            .buttonStyle(.borderedProminent)

            let favorited = shot.id.map(store.isFavorite) ?? false
            Button {
                store.toggleFavorite(shot)
            } label: {
                Label(favorited ? "取消收藏" : "收藏", systemImage: favorited ? "star.fill" : "star")
                    .foregroundStyle(favorited ? Color.yellow : Color.primary)
            }
            .labelStyle(.iconOnly)
            .help(favorited ? "取消收藏" : "收藏")

            Button {
                pin()
            } label: {
                Label("钉图", systemImage: "pin")
            }
            .labelStyle(.iconOnly)
            .help("钉在桌面")

            Button {
                export()
            } label: {
                Label("导出", systemImage: "square.and.arrow.up")
            }
            .labelStyle(.iconOnly)
            .help("导出成品（含标注）")

            Spacer(minLength: 0)

            moreMenu
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private var moreMenu: some View {
        Menu {
            Button {
                openSource()
            } label: {
                Label("回到出处", systemImage: "arrow.up.forward.app")
            }
            .disabled(shot.sourceURL == nil && shot.appBundleID == nil)

            Button {
                showingSimilar = true
            } label: {
                Label("查找相似", systemImage: "sparkles.rectangle.stack")
            }
            .disabled(!hasFeaturePrint)

            Button {
                showingTimeline = true
            } label: {
                Label("同源时间线", systemImage: "clock.arrow.circlepath")
            }
            .disabled(relatedCount < 2)

            Divider()

            Button {
                Clipboard.copy(text: BugReport.markdown(
                    shot: shot,
                    pixelWidth: shot.pixelWidth,
                    pixelHeight: shot.pixelHeight
                ))
            } label: {
                Label("复制 Bug 报告", systemImage: "ladybug")
            }

            Button {
                upload()
            } label: {
                Label("上传图床", systemImage: "arrow.up.circle")
            }
            .disabled(
                AppSettings.shared.uploadEndpoint
                    .trimmingCharacters(in: .whitespaces).isEmpty
            )
        } label: {
            Label("更多", systemImage: "ellipsis.circle")
        }
        .labelStyle(.iconOnly)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("更多动作：出处 / 相似 / 时间线 / Bug 报告 / 上传")
    }

    private func pin() {
        guard let base = store.originalImage(for: shot) else { return }
        PinWindowController.pin(
            base: base,
            layers: store.latestRevision(for: shot)?.imageLayers ?? Layers(),
            shot: shot,
            at: .zero
        )
    }

    /// 上传图床：复用截图工具条的 UploadAction，材料从图库记录重建。
    private func upload() {
        guard let base = store.originalImage(for: shot) else { return }
        let context = CaptureContext(
            base: base,
            layers: store.latestRevision(for: shot)?.imageLayers ?? Layers(),
            shot: shot,
            region: nil,
            host: nil
        )
        Task {
            do {
                try await UploadAction().perform(context)
            } catch {
                let alert = NSAlert()
                alert.messageText = "上传失败"
                alert.informativeText = error.localizedDescription
                if let window = GalleryWindowController.shared.window {
                    alert.beginSheetModal(for: window) { _ in }
                } else {
                    alert.runModal()
                }
            }
        }
    }

    /// 回到出处：优先开网址（默认浏览器），否则激活来源 App。
    private func openSource() {
        if let source = shot.sourceURL, let url = URL(string: source) {
            SystemNavigator.open(url: url)
        } else if let bundleID = shot.appBundleID {
            SystemNavigator.activateApp(bundleID: bundleID)
        }
    }

    // MARK: - 信息分组卡片

    /// 分组卡片：quaternary 底 + 卡片圆角 + caption.semibold 组题。
    private func card(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: DS.s2) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
        .padding(DS.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: DS.radiusCard))
    }

    private var sourceCard: some View {
        card("来源") {
            row("App", shot.appName)
            row("Bundle ID", shot.appBundleID)
            row("版本", shot.appVersion.map { v in
                shot.appBuild.map { "\(v) (\($0))" } ?? v
            })
            row("窗口标题", shot.windowTitle)
            if let url = shot.sourceURL {
                VStack(alignment: .leading, spacing: 2) {
                    Text("网址").font(.caption).foregroundStyle(.secondary)
                    Link(url, destination: URL(string: url) ?? URL(string: "about:blank")!)
                        .font(.caption)
                        .lineLimit(3)
                }
            }
            row("显示器", shot.displayName)
            row("尺寸", "\(shot.pixelWidth) × \(shot.pixelHeight) px @\(String(format: "%.0f", shot.scale))x")
            row("时间", shot.capturedAt.formatted(date: .abbreviated, time: .standard))
        }
    }

    /// 机器补出来的信息（分类、OCR）单独一组，和采集自系统的「来源」分开。
    @ViewBuilder
    private var recognitionCard: some View {
        let ocr = shot.ocrText ?? ""
        if category != nil || !ocr.isEmpty {
            card("识别") {
                row("分类", category)
                if !ocr.isEmpty {
                    DisclosureGroup("识别文字（\(ocr.count) 字）") {
                        Text(ocr)
                            .font(.caption)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, DS.s1)
                    }
                    .font(.caption)
                }
            }
        }
    }

    private var historyCard: some View {
        card("修订历史（\(revisions.count)）") {
            Text("每次编辑都追加一条记录，原图从不被修改。")
                .font(.caption2)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(revisions.enumerated()), id: \.element.id) { index, rev in
                    RevisionRow(
                        revision: rev,
                        isLatest: index == revisions.count - 1,
                        isFirst: index == 0,
                        isLast: index == revisions.count - 1
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: DS.s2) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 64, alignment: .leading)
                Text(value)
                    .font(.caption)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func export() {
        guard let base = store.originalImage(for: shot) else { return }
        let rendered = LayerRenderer.render(
            base: base,
            layers: store.latestRevision(for: shot)?.imageLayers ?? Layers()
        )
        _ = try? ImageExporter.exportWithPanel(
            rendered,
            suggestedName: ImageExporter.suggestedName(for: shot)
        )
    }
}

/// 修订历史的一行：左侧 2pt 竖线把圆点连成真时间线，行内容 hover 提亮。
private struct RevisionRow: View {
    let revision: RevisionSummary
    let isLatest: Bool
    let isFirst: Bool
    let isLast: Bool

    @State private var isHovering = false

    var body: some View {
        ZStack(alignment: .leading) {
            // 连线分上下两段等分行高，中间给圆点留 8pt；首行缺上段、末行缺下段。
            VStack(spacing: 0) {
                connector.opacity(isFirst ? 0 : 1)
                Color.clear.frame(height: 8)
                connector.opacity(isLast ? 0 : 1)
            }
            .padding(.leading, 3)

            Circle()
                .fill(isLatest ? Color.accentColor : Color.secondary.opacity(0.55))
                .frame(width: 8, height: 8)

            HStack(spacing: DS.s2) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("v\(revision.version) · \(revision.note)")
                        .font(.caption)
                    Text("\(revision.layerCount) 个图层 · \(revision.createdAt.formatted(date: .omitted, time: .shortened))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, DS.s4)
            .padding(.vertical, DS.s1)
        }
        .background(
            RoundedRectangle(cornerRadius: DS.radiusSmall)
                .fill(Color.primary.opacity(isHovering ? 0.06 : 0))
        )
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
    }

    private var connector: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.3))
            .frame(width: 2)
            .frame(maxHeight: .infinity)
    }
}

// MARK: - 相似截图

/// 「查找相似」结果。指纹距离在 ShotStore 里已算好并升序排好，这里只管展示。
private struct SimilarShotsSheet: View {
    let shot: Shot

    @Environment(\.dismiss) private var dismiss
    /// nil = 还在比对；空数组 = 比对完但没有可比的候选。
    @State private var results: [Shot]?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("相似截图", systemImage: "sparkles.rectangle.stack")
                    .font(.headline)
                Spacer()
                Button("关闭") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(14)

            Divider()

            if let results {
                if results.isEmpty {
                    ContentUnavailableView(
                        "没有可比对的截图",
                        systemImage: "sparkles.rectangle.stack",
                        description: Text("其它截图还没完成特征分析，稍后再试")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 150, maximum: 210), spacing: 14)],
                            spacing: 16
                        ) {
                            ForEach(results) { result in
                                SimilarShotCard(shot: result)
                                    .onTapGesture {
                                        // 定位类场景：清空多选后单选目标。
                                        GallerySelection.shared.select(only: result.id)
                                        dismiss()
                                    }
                            }
                        }
                        .padding(16)
                    }
                }
            } else {
                ProgressView("正在比对特征指纹…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 640, height: 440)
        .task(id: shot.id) {
            results = await ShotStore.shared.similarShots(to: shot)
        }
    }
}

/// 相似结果卡片：缩略图 + App 名 + 时间。刻意比 ShotCard 简单 ——
/// 结果按相似度排序本身就是提示，不展示精确距离数值。
private struct SimilarShotCard: View {
    let shot: Shot

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.quaternary.opacity(0.5))
                CachedImage(url: ShotStore.shared.thumbnailURL(for: shot), key: shot.sha256)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .frame(height: 100)
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.primary.opacity(isHovering ? 0.3 : 0.08), lineWidth: 1)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(shot.appName ?? "未知 App")
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                Text(shot.capturedAt, format: .dateTime.month().day().hour().minute())
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 2)
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
    }
}
