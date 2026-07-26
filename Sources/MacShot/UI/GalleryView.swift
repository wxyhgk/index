import SwiftUI
import AppKit

@MainActor
final class GallerySelection: ObservableObject {
    static let shared = GallerySelection()
    @Published var selectedID: Int64?
    @Published var editing: Shot?
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

    private var semanticAvailable: Bool {
        settings.semanticSearch && modelStore.isReady
    }

    private var selectedShot: Shot? {
        // 语义结果可能不在常规列表（最近 500 张）里，两边都找。
        store.displayShots.first { $0.id == selection.selectedID }
            ?? store.shots.first { $0.id == selection.selectedID }
    }

    var body: some View {
        NavigationSplitView {
            GallerySidebar()
                .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 280)
        } content: {
            GalleryGrid()
                .navigationSplitViewColumnWidth(min: 420, ideal: 640)
        } detail: {
            if let shot = selectedShot {
                ShotDetailPane(shot: shot)
                    .navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 420)
            } else {
                ContentUnavailableView(
                    "未选择截图",
                    systemImage: "photo.on.rectangle",
                    description: Text("在中间选择一张截图查看详情")
                )
                .navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 420)
            }
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
        }
        .onChange(of: store.semanticMode) { _, semantic in
            if !semantic { store.clearSemanticResults() }
        }
        .frame(minWidth: 1000, minHeight: 600)
        .sheet(item: $selection.editing) { shot in
            EditorView(shot: shot)
        }
    }
}

// MARK: - 侧边栏

private struct GallerySidebar: View {

    @ObservedObject private var store = ShotStore.shared

    @State private var categories: [(name: String, count: Int)] = []
    @State private var apps: [(name: String, bundleID: String?, count: Int)] = []
    @State private var total = 0

    var body: some View {
        List(selection: filterBinding) {
            Section("资料库") {
                Label("全部截图", systemImage: "square.grid.2x2")
                    .badge(total)
                    .tag(ShotStore.GalleryFilter.all)
                Label("收藏", systemImage: "star")
                    .badge(store.favoriteCount())
                    .tag(ShotStore.GalleryFilter.favorites)
            }

            if !categories.isEmpty {
                Section("分类") {
                    ForEach(categories, id: \.name) { category in
                        Label(category.name, systemImage: icon(forCategory: category.name))
                            .badge(category.count)
                            .tag(ShotStore.GalleryFilter.category(category.name))
                    }
                }
            }

            if !apps.isEmpty {
                Section("应用") {
                    ForEach(apps, id: \.name) { app in
                        HStack(spacing: 6) {
                            AppIconView(bundleID: app.bundleID)
                            Text(app.name).lineLimit(1)
                        }
                        .badge(app.count)
                        .tag(ShotStore.GalleryFilter.app(app.name))
                    }
                }
            }
        }
        .listStyle(.sidebar)
        // 聚合是三条小查询，跟着数据量变化刷新即可，不挂在每次重绘上。
        .task(id: store.shots.count) { refresh() }
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

    @ObservedObject private var store = ShotStore.shared
    @ObservedObject private var selection = GallerySelection.shared

    /// 缩略图基准宽度，底部滑杆控制，跨启动记住。
    @AppStorage("galleryZoom") private var zoom = 200.0

    /// 按时间段分好组的结果，随 store.shots 变化重算一次。
    @State private var sections: [ShotSection] = []

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: zoom, maximum: zoom * 1.5), spacing: 16)]
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
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(sections) { section in
                            Text(section.title)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            LazyVGrid(columns: columns, spacing: 18) {
                                ForEach(section.shots) { shot in
                                    ShotCard(
                                        shot: shot,
                                        height: zoom * 0.68,
                                        isSelected: shot.id == selection.selectedID,
                                        isFavorite: shot.id.map(store.isFavorite) ?? false,
                                        onToggleFavorite: { store.toggleFavorite(shot) }
                                    )
                                    .onTapGesture { selection.selectedID = shot.id }
                                    .simultaneousGesture(
                                        TapGesture(count: 2).onEnded { selection.editing = shot }
                                    )
                                    .contextMenu { contextMenu(for: shot) }
                                }
                            }
                            .padding(.bottom, 8)
                        }
                    }
                    .padding(18)
                }
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
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(emptyTitle, systemImage: emptyIcon)
        } description: {
            Text(emptyDescription)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        HStack(spacing: 12) {
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
            Image(systemName: "photo")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            Slider(value: $zoom, in: 140...320)
                .frame(width: 140)
                .controlSize(.small)
            Image(systemName: "photo")
                .font(.system(size: 13))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(.bar)
    }

    @ViewBuilder
    private func contextMenu(for shot: Shot) -> some View {
        Button(shot.id.map(store.isFavorite) ?? false ? "取消收藏" : "收藏") {
            store.toggleFavorite(shot)
        }
        Button("编辑标注") { selection.editing = shot }
        Button("钉在桌面") { pin(shot) }
        Button("复制图片") { copy(shot) }
        Divider()
        Button("出处") { openSource(of: shot) }
            .disabled(shot.sourceURL == nil && shot.appBundleID == nil)
        Button("在访达中显示") {
            SystemNavigator.revealInFinder(store.originalURL(for: shot))
        }
        Button("删除", role: .destructive) { store.delete(shot) }
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

// MARK: - 卡片

private struct ShotCard: View {
    let shot: Shot
    let height: CGFloat
    let isSelected: Bool
    /// 收藏态由父级（已订阅 store 的 GalleryGrid）传入，卡片本身保持不订阅。
    let isFavorite: Bool
    let onToggleFavorite: () -> Void

    @State private var isHovering = false

    // 刻意不用 @ObservedObject 订阅 store —— 只需要一个文件路径，
    // 订阅了会导致任何 store 变化都重建全部缩略图。
    private var thumbnailURL: URL { ShotStore.shared.thumbnailURL(for: shot) }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(.quaternary.opacity(0.5))
                CachedImage(url: thumbnailURL, key: shot.sha256)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .frame(height: height)
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(
                        isSelected
                            ? Color.accentColor
                            : Color.primary.opacity(isHovering ? 0.25 : 0.08),
                        lineWidth: isSelected ? 2.5 : 1
                    )
            }
            // 悬停浮出星形按钮；已收藏则常显实心黄星。
            .overlay(alignment: .topTrailing) {
                if isHovering || isFavorite {
                    Button(action: onToggleFavorite) {
                        Image(systemName: isFavorite ? "star.fill" : "star")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(isFavorite ? .yellow : .white)
                            .shadow(color: .black.opacity(0.5), radius: 2)
                            .padding(7)
                    }
                    .buttonStyle(.plain)
                    .help(isFavorite ? "取消收藏" : "收藏")
                }
            }
            .shadow(
                color: .black.opacity(isHovering || isSelected ? 0.18 : 0.08),
                radius: isHovering ? 7 : 3,
                y: 2
            )
            .scaleEffect(isHovering && !isSelected ? 1.015 : 1)
            .animation(.easeOut(duration: 0.12), value: isHovering)
            .animation(.easeOut(duration: 0.12), value: isSelected)

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
        .onHover { isHovering = $0 }
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
    /// 敏感内容检测结果（后台异步落库，和指纹一样随 store 刷新重查）。
    @State private var sensitiveRegions: [SensitiveRegion] = []
    /// 是否已打码。加载时按「最新修订的马赛克层是否盖住全部命中区域」判定，
    /// 一键打码完成后直接置真。
    @State private var sensitiveMasked = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                preview
                actions
                metadataActions
                Divider()
                if !sensitiveRegions.isEmpty {
                    sensitiveBanner
                }
                metadataSection
                Divider()
                historySection
            }
            .padding(16)
        }
        .task(id: shot.id) {
            loadRevisions()
            category = shot.id.flatMap { store.attributeText(shotID: $0, key: AttributeKey.category) }
            refreshFeaturePrint()
            refreshSensitiveRegions()
        }
        // 指纹由后台分析异步补上：store 每次刷新（属性落库会触发 reload）都重查一次。
        // 属性写入不一定改变 shots 数组本身，所以订阅 objectWillChange 而不是 onChange。
        // 单行 LIMIT 1 查询，代价可忽略。
        .onReceive(store.objectWillChange) { _ in
            refreshFeaturePrint()
            refreshSensitiveRegions()
        }
        .onChange(of: selection.editing) { _, newValue in
            if newValue == nil { loadRevisions() }
        }
        .sheet(isPresented: $showingSimilar) {
            SimilarShotsSheet(shot: shot)
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
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
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
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.yellow.opacity(0.18))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
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
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button {
                selection.editing = shot
            } label: {
                Label("编辑", systemImage: "pencil.tip.crop.circle")
            }
            Button {
                store.toggleFavorite(shot)
            } label: {
                let favorited = shot.id.map(store.isFavorite) ?? false
                Label(favorited ? "已收藏" : "收藏", systemImage: favorited ? "star.fill" : "star")
                    .foregroundStyle(favorited ? Color.yellow : Color.primary)
            }
            Button {
                guard let base = store.originalImage(for: shot) else { return }
                PinWindowController.pin(
                    base: base,
                    layers: store.latestRevision(for: shot)?.imageLayers ?? Layers(),
                    shot: shot,
                    at: .zero
                )
            } label: {
                Label("钉图", systemImage: "pin")
            }
            Button {
                showingSimilar = true
            } label: {
                Label("相似", systemImage: "sparkles.rectangle.stack")
            }
            .disabled(!hasFeaturePrint)
            .help(hasFeaturePrint ? "查找视觉相似的截图" : "特征分析中，稍后再试")
            Button {
                export()
            } label: {
                Label("导出", systemImage: "square.and.arrow.up")
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    /// 第二行：消费元数据的动作。和第一行分开是因为 HStack 不折行。
    private var metadataActions: some View {
        HStack(spacing: 8) {
            Button {
                openSource()
            } label: {
                Label("出处", systemImage: "arrow.up.forward.app")
            }
            .disabled(shot.sourceURL == nil && shot.appBundleID == nil)
            .help("回到截图来源：有网址开网址，否则激活来源 App")
            Button {
                Clipboard.copy(text: BugReport.markdown(
                    shot: shot,
                    pixelWidth: shot.pixelWidth,
                    pixelHeight: shot.pixelHeight
                ))
            } label: {
                Label("复制 Bug 报告", systemImage: "ladybug")
            }
            .help("把来源、环境等元数据整理成 Markdown 放进剪贴板")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    /// 回到出处：优先开网址（默认浏览器），否则激活来源 App。
    private func openSource() {
        if let source = shot.sourceURL, let url = URL(string: source) {
            SystemNavigator.open(url: url)
        } else if let bundleID = shot.appBundleID {
            SystemNavigator.activateApp(bundleID: bundleID)
        }
    }

    private var metadataSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("来源").font(.headline)
            row("App", shot.appName)
            row("分类", category)
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

            if let ocr = shot.ocrText, !ocr.isEmpty {
                DisclosureGroup("识别文字（\(ocr.count) 字）") {
                    Text(ocr)
                        .font(.caption)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.caption)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("修订历史（\(revisions.count)）").font(.headline)
            Text("每次编辑都追加一条记录，原图从不被修改。")
                .font(.caption2)
                .foregroundStyle(.secondary)

            ForEach(revisions) { rev in
                let isLatest = rev.id == revisions.last?.id
                HStack(spacing: 8) {
                    Image(systemName: isLatest ? "circle.fill" : "circle")
                        .font(.system(size: 7))
                        .foregroundStyle(isLatest ? Color.accentColor : .secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("v\(rev.version) · \(rev.note)")
                            .font(.caption)
                        Text("\(rev.layerCount) 个图层 · \(rev.createdAt.formatted(date: .omitted, time: .shortened))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            HStack(alignment: .top, spacing: 8) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 74, alignment: .leading)
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
                                        GallerySelection.shared.selectedID = result.id
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
