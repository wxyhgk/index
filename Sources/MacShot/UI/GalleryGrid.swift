import SwiftUI
import AppKit

// MARK: - 网格
//
// 图库中栏：时间分组（ShotSection）、网格 / 瀑布两种显示模式（GalleryLayoutMode）、
// 稳定列宽数学、卡片装配与右键菜单、空态与底部缩放条，
// 以及全图库唯一的那套删除确认框。

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

/// 图库显示模式：网格（固定高度，裁切显示）/ 瀑布（等宽不裁切，Eagle 式）。
private enum GalleryLayoutMode: String {
    case grid
    case waterfall
}

struct GalleryGrid: View {

    /// 外层（不受滚动条出没影响的）可用宽度，列数由它显式算出。
    let width: CGFloat

    @ObservedObject private var store = ShotStore.shared
    @ObservedObject private var selection = GallerySelection.shared
    /// 只为一个开关订阅：逐卡滚动深度（`galleryScrollDepth`）。
    /// 设置项的变更频率是「用户偶尔点一下」，用它换「关掉开关立刻生效」是划算的。
    @ObservedObject private var settings = AppSettings.shared

    /// 缩略图基准宽度，底部滑杆控制，跨启动记住。
    /// 瀑布模式下同一个值语义变成「列宽基准」，滑杆行为自然成立。
    @AppStorage("galleryZoom") private var zoom = 200.0

    /// 显示模式，底部条切换，跨启动记住。
    @AppStorage("galleryLayout") private var layoutMode = GalleryLayoutMode.grid

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
    private func columnMetrics(for width: CGFloat) -> (itemWidth: CGFloat, count: Int) {
        var count = max(1, Int((width - 2 * DS.s4 + DS.s4) / (zoom + DS.s4)))
        // 给常驻滚动条预留：列宽按可用宽扣除 16pt 计算，列数不受它出没影响。
        let usable = width - 2 * DS.s4 - 16 - CGFloat(count - 1) * DS.s4
        if usable < CGFloat(count) * zoom * 0.6 { count = max(1, count - 1) }
        let itemWidth = max(80, (width - 2 * DS.s4 - 16 - CGFloat(count - 1) * DS.s4) / CGFloat(count))
        return (itemWidth, count)
    }

    private func fixedColumns(for width: CGFloat) -> (items: [GridItem], count: Int) {
        let metrics = columnMetrics(for: width)
        return (
            Array(repeating: GridItem(.fixed(metrics.itemWidth), spacing: DS.s4), count: metrics.count),
            metrics.count
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

            // 网格 ↔ 底栏之间不画 Divider()：底栏的材质边界本身就是分界，
            // 再叠一条 1px 实线是第二条边，两条线互相削弱（见底栏的 hairline: .top）。
            bottomBar
        }
        // L0 画布：**不透明**。几百张缩略图铺在桌面模糊上是纯粹的视觉噪音，
        // 而且白付一份 behind-window 采样成本 —— 那份成本是「每窗口」的，
        // 花在内容层上完全没有回报。Apple 自家 Photos 的网格同样是纯不透明底。
        //
        // 铺在 VStack 这一层是为了让空态（ContentUnavailableView）也有同一块底 ——
        // 否则筛不到结果时中栏会露出窗口底色，和有内容时不是一个灰。
        // ScrollView 自己那份见 `grid`：两者的帧不同，工具栏底下那 52pt 只有它盖得住。
        .background(Color(nsColor: .underPageBackgroundColor))
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
        // 单事务批量删除：逐张 delete 会打出「张数 × (写 + 读 + 全量 reload)」的主线程风暴。
        store.delete(targets)
        let remaining = store.displayShots
        if let anchorIndex, !remaining.isEmpty {
            selection.select(only: remaining[min(anchorIndex, remaining.count - 1)].id)
        } else {
            selection.select(only: nil)
        }
    }

    private var grid: some View {
        let layout = fixedColumns(for: width)
        // 瀑布模式各列行高不齐，「上下 = ±列数」的网格假设失效 ——
        // 键盘列数报 1，上下键退化为顺序前后（和左右一致）。
        let keyboardColumns = layoutMode == .waterfall ? 1 : layout.count
        return ScrollViewReader { proxy in
            ScrollView {
                if layoutMode == .waterfall {
                    waterfall
                } else {
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
                                    card(for: shot, height: zoom * 0.68)
                                }
                            } header: {
                                sectionHeader(for: section)
                            }
                        }
                    }
                    .padding(.horizontal, DS.s4)
                    .padding(.bottom, DS.s3)
                }
            }
            // ScrollView 在 macOS 上自带一层不透明底（windowBackgroundColor）。
            // 不关掉的话它会盖住上面那层 underPageBackgroundColor 画布，
            // 两种灰打架，且侧边栏 / 底栏的材质会显得对不上底色。
            .scrollContentBackground(.hidden)
            // 画布色再铺一份到 ScrollView 自己身上：它的帧一直伸到窗口顶（工具栏底下），
            // 而外层 VStack 的帧是从工具栏下沿才开始的。少了这一份，
            // unified 工具栏的材质采样到的是窗口底色而不是画布色，工具栏会和网格差一档灰。
            .background(Color(nsColor: .underPageBackgroundColor))
            //
            // ⚠️ 这里**故意不挂** `.scrollEdgeMask(topInset:)`，原因是实测出来的，不是取舍：
            //
            // 本窗口是 fullSizeContentView + unified 工具栏，SwiftUI 给这个 ScrollView
            // 的 NSScrollView 设了 contentInsets.top = 52（工具栏高度），于是
            //   · 内容**不会**露在工具栏底下（52pt 那条带子里只有画布色，没有可「化开」的东西）；
            //   · 吸顶分组头 pin 的位置 = SwiftUI 侧 ScrollView 帧的顶边 y = 52，
            //     和 mask 渐变带的起点**完全重合**。
            // 结果就是渐变带整条压在吸顶头上，把分组头本身淡成半透明（实测：
            // 28pt 渐变让 .title3 的分组头顶部 2/3 透出底下的画布色）。
            // 规格要的是「卡片滑进标题时化开」，不是「标题自己化没」。
            //
            // 冻结的 `ScrollEdgeMask` 只有 topInset、没有「渐变带起点下移」的参数，
            // 在有 pinnedViews 的容器上无解 —— 这条已写进交付报告，等底座补 API。
            // 顶部边缘的「化开」当前由逐卡 `scrollDepth()` 承担（见 card(for:)）。
            .onChange(of: keyboardColumns, initial: true) { _, count in
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

    /// 瀑布模式内容：外层 LazyVStack 保持**组级**懒加载 + 吸顶头，
    /// 每个时间段内用 WaterfallLayout 一次排完（Layout 协议不懒，
    /// 单段几十张全实例化可接受；几百张的库靠分段兜住）。
    /// 这是「懒容器套非懒容器」—— 和出过事的 LazyVStack>LazyVGrid 双懒嵌套不同，
    /// Layout 是确定性布局，没有内层懒实例化与吸顶 pin 的竞态。
    private var waterfall: some View {
        let metrics = columnMetrics(for: width)
        return LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
            ForEach(sections) { section in
                Section {
                    WaterfallLayout(
                        columnCount: metrics.count,
                        columnWidth: metrics.itemWidth,
                        spacing: DS.s4
                    ) {
                        ForEach(section.shots) { shot in
                            card(for: shot, height: waterfallHeight(for: shot, columnWidth: metrics.itemWidth))
                        }
                    }
                    .padding(.bottom, DS.s4)
                } header: {
                    sectionHeader(for: section)
                }
            }
        }
        .padding(.horizontal, DS.s4)
        .padding(.bottom, DS.s3)
    }

    /// 瀑布卡片的缩略图高度 = **可用图宽** / 图片长宽比。
    /// 尺寸元数据（pixelWidth/Height）建库时就有，不用解码图片。
    /// 缩略图生成是等比缩放（ImageCodec.resized），CachedImage 的 .fit
    /// 在这个高度下正好铺满，不裁切也不留边。
    ///
    /// 可用图宽 = 列宽 − 2×`DS.s1`：卡片的缩略图在卡面内左右各内缩 4pt
    ///（同心圆角要求：内圆角 = 10 − 4 = 6）。按整个列宽算高会多算 4~5pt，
    /// `.fit` 之下就变成上下各留一条空边 —— 瀑布模式「等宽不裁切、完整贴合」的
    /// 全部意义就在于没有这条边。
    private func waterfallHeight(for shot: Shot, columnWidth: CGFloat) -> CGFloat {
        let pixelWidth = CGFloat(max(1, shot.pixelWidth))
        let pixelHeight = CGFloat(max(1, shot.pixelHeight))
        let imageWidth = max(1, columnWidth - 2 * DS.s1)
        return imageWidth * pixelHeight / pixelWidth
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

    /// 逐卡滚动深度。规格里它是**次选**（首选是成本恒定的容器级 `scrollEdgeMask`），
    /// 但那条在本窗口的「工具栏 + 吸顶头」结构下会把分组头本身淡掉（理由见 `grid`），
    /// 所以这里是当前唯一的滚动边缘表达 —— 也正因如此它才必须配一个开关：
    /// 代价 ∝ 可见卡片数，几千张的库要能关掉。
    /// 这一层只用 opacity / scale / offset —— 绝不碰 blur：
    /// blur 在 scrollTransition 里是「逐帧离屏渲染 × 可见卡片数」，
    /// SwiftUI 的 .blur 动画实测能吃掉 50% CPU（等价效果走 CALayer 是 0%）。
    /// 开关关掉时走 else 分支，效果连同 scrollTransition 一起消失（不是设成 identity 空转）。
    /// 代价是切换开关那一下卡片会因 `_ConditionalContent` 换分支重建一次 —— 一次性的，可接受。
    @ViewBuilder
    private func card(for shot: Shot, height: CGFloat) -> some View {
        if settings.galleryScrollDepth {
            cardBody(for: shot, height: height).scrollDepth()
        } else {
            cardBody(for: shot, height: height)
        }
    }

    private func cardBody(for shot: Shot, height: CGFloat) -> some View {
        ShotCard(
            shot: shot,
            height: height,
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
                GalleryWindowMode.shared.openEditor(shotID: shot.id)
            }
        )
        // 不给 preview 闭包：默认预览就是这张卡自己的快照，多选时也照样跟手，
        // 语义上也诚实 —— 拖出到外部本来就只导出这一张（见 ShotDragFile 的取舍注释），
        // 现在去做 Finder 那种「叠张 + 数字角标」反而会承诺一个不存在的行为。
        // 何况自定义 preview 的 ViewBuilder 和载荷一样在 body 里逐卡片求值，是要还的。
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
            // 布局切换是「整片内容重排」，用 standard（0.35 / 0.85）：
            // 比系统默认的 0.55 利落，又不像 micro 那样快到读不出内容是怎么挪的。
            // 动画包在 setter 的事务里而不是给网格挂常驻 .animation(value:) ——
            // 后者会让网格里任何一次尺寸变化（比如缩放滑杆）都被顺带动画掉。
            Picker("显示模式", selection: Binding(
                get: { layoutMode },
                set: { newValue in withAnimation(DS.Motion.standard) { layoutMode = newValue } }
            )) {
                Image(systemName: "square.grid.2x2")
                    .tag(GalleryLayoutMode.grid)
                Image(systemName: "square.grid.3x1.below.line.grid.1x2")
                    .tag(GalleryLayoutMode.waterfall)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
            .help("网格：整齐等高，超出裁切；瀑布：等宽不裁切，完整显示长图")
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
        // L2 chrome：材质边界代替 Divider()。发丝线只画顶边一条 ——
        // 深色 white 0.10 是「顶边接光」，浅色 black 0.09 是「底边自遮挡」，
        // 方向和卡片描边渐变同源（全 App 只有一个光源方向）。
        // .withinWindow 而不是 .behindWindow：底栏下面是自家的不透明画布，
        // 没有桌面可借，而 behindWindow 的成本是每窗口的，一份要留给侧边栏。
        .glassPanel(.headerView, blending: .withinWindow, hairline: .top)
    }

    @ViewBuilder
    private func contextMenu(for shot: Shot) -> some View {
        Button(shot.id.map(store.isFavorite) ?? false ? "取消收藏" : "收藏") {
            store.toggleFavorite(shot)
        }
        Button("编辑标注") { GalleryWindowMode.shared.openEditor(shotID: shot.id) }
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
        ShotDragFile(shot: shot, shotIDs: draggedIDs(for: shot))
    }

    /// 拖拽携带哪些 ID：被拖的这张在多选集合里 → 全部选中项；不在 → 只有它自己。
    /// 这是 Finder 的行为，也是「先框选一批、再一把拖到侧边栏标签上」能成立的前提。
    ///
    /// 同样受上面那条廉价纪律约束：命中多选时是 `Set` 的 COW 引用拷贝（O(1)，不遍历），
    /// 未命中时新建一个单元素 Set。**不要**改成去 `store.displayShots` 里按展示顺序过滤 ——
    /// 那是「全库长度 × 可见卡片数」的每帧扫描，而打标签根本不需要顺序。
    private func draggedIDs(for shot: Shot) -> Set<Int64> {
        guard let id = shot.id else { return [] }
        return selection.isSelected(id) ? selection.selectedIDs : [id]
    }

    /// 钉在桌面：走注册表的 pin 动作（界面层不直接建窗口），材料从图库记录重建。
    private func pin(_ shot: Shot) {
        guard let base = store.originalImage(for: shot) else { return }
        let context = CaptureContext(
            base: base,
            layers: store.latestRevision(for: shot)?.imageLayers ?? Layers(),
            shot: shot,
            region: nil,
            host: nil
        )
        Task { try? await CaptureActionRegistry.shared.action(id: ActionID.pin)?.perform(context) }
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
