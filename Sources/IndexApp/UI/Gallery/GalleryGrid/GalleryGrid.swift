import SwiftUI
import AppKit

// MARK: - 网格
//
// 图库中栏：时间分组（ShotSection）、网格 / 瀑布两种显示模式（GalleryLayoutKind）、
// 稳定列宽数学、卡片装配与右键菜单、空态与可选的底部悬浮工具条，
// 以及全图库唯一的那套删除确认框。
//
// 2026-07 改版的两件结构性变化：
//   1. **画布交还窗口底色**（原来这里铺一层不透明的 `underPageBackgroundColor`）。
//      逐条核对见 `body` 上的注释 —— 三条旧理由现在一条都不成立了。
//   2. **图库首页不再显示重复的底部控制条。** 显示模式已在顶栏，缩略图尺寸收进
//      更多菜单；其他 destination 暂时保留旧胶囊，避免这一轮越界改动。
//
// 文件布局（按职责拆分，其余文件都是本类型的扩展或子视图）：
//   · `GalleryGridSupport`        顶层支撑类型（时间分组/快照键/视觉预算，可独立单测）
//   · `GalleryFloatingToolbar`    底部悬浮工具条（独立子视图）
//   · `GalleryGrid+Card`          卡片装配、右键菜单、单张动作
//   · `GalleryGrid+Data`          快照刷新与分页
// 本文件保留：视图属性、列宽数学、body、网格/瀑布布局、空态、删除确认。

struct GalleryGrid: View {

    /// 写访问为同类型扩展（+Card / +Data）放开；
    /// 外部代码不直接持有 GalleryGrid 的这些依赖。
    @ObservedObject var store: ShotStore
    @ObservedObject var sessionLifecycle: GallerySessionLifecycle
    let viewModel: GalleryViewModel
    @StateObject var presentation: GalleryGridPresentation
    @ObservedObject private var imageImporter: ImageImportCoordinator
    @EnvironmentObject var selection: GallerySelection
    @EnvironmentObject var batchActivity: GalleryBatchActivity
    @Environment(\.galleryKeyboard) private var keyboard
    private let scope: GalleryContentScope
    private let chrome: GalleryGridChrome

    init(
        store: ShotStore = .shared,
        viewModel: GalleryViewModel? = nil,
        sessionLifecycle: GallerySessionLifecycle? = nil,
        settings: AppSettings = .shared,
        scope: GalleryContentScope = .library,
        chrome: GalleryGridChrome = .standard
    ) {
        _store = ObservedObject(wrappedValue: store)
        _sessionLifecycle = ObservedObject(wrappedValue: sessionLifecycle ?? .shared)
        let resolvedViewModel = viewModel
            ?? .resolve(for: store)
        self.viewModel = resolvedViewModel
        _presentation = StateObject(wrappedValue: GalleryGridPresentation(viewModel: resolvedViewModel))
        _imageImporter = ObservedObject(wrappedValue: .resolve(for: store))
        _settings = ObservedObject(wrappedValue: settings)
        self.scope = scope
        self.chrome = chrome
    }
    /// 只为一个开关订阅：逐卡滚动深度（`galleryScrollDepth`）。
    /// 设置项的变更频率是「用户偶尔点一下」，用它换「关掉开关立刻生效」是划算的。
    /// 写访问为 +Card 扩展放开（上传配置 / 滚动深度开关）。
    @ObservedObject var settings: AppSettings

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 缩略图基准宽度，底部滑杆控制，跨启动记住。
    /// 瀑布模式下同一个值语义变成「列宽基准」，滑杆行为自然成立。
    @AppStorage("galleryZoom") private var zoom = 200.0

    /// 显示模式，底部悬浮工具条切换，跨启动记住。
    ///
    /// 类型是 `GalleryLayoutKind`（定义在 `GalleryTopBar.swift`）。这里曾经有一个
    /// 私有的 `GalleryLayoutMode` 副本 —— 同一个 `@AppStorage("galleryLayout")` 键、
    /// 同一组 rawValue，**两份定义、一份数据**。副本已删除：加一个 case 却只改一边
    /// 就会得到「顶栏能切到、网格不认识」的静默错位，这种坑不留。
    @AppStorage("galleryLayout") private var layoutMode = GalleryLayoutKind.grid

    /// 按时间段分好组的结果，随 store.shots 变化重算一次（+Data 扩展写它）。
    @State var sections: [ShotSection] = []
    /// 当前可见集合的派生信息与对应 ID 一次发布。分页只查新增后缀并 merge，避免
    /// 第 N 页到来时重新读取前 N-1 页；五份独立 @State 也收敛为一次视图失效。
    @State var metadataSnapshot = GalleryGridMetadataSnapshot.empty
    var categoriesByShot: [Int64: String] { metadataSnapshot.metadata.categoriesByShot }
    var annotatedIDs: Set<Int64> { metadataSnapshot.metadata.annotatedShotIDs }
    var recordingPathsByShot: [Int64: String] { metadataSnapshot.metadata.recordingPathsByShot }
    var collectionSummaries: [ShotCollectionSummary] { metadataSnapshot.metadata.collectionSummaries }
    var collectionIDsByShot: [Int64: Set<Int64>] { metadataSnapshot.metadata.collectionIDsByShot }
    /// 全选可能跨越尚未加载的分页；菜单只保存“每个专题集命中多少张”，不为
    /// 数万张选中项构造逐图成员字典（+Card / +Data 扩展读写它）。
    @State var selectedCollectionMembershipCounts: [Int64: Int] = [:]
    @State var selectedCollectionSnapshotGeneration = -1
    /// 右键菜单打开的时间线 / 相似 sheet（+Card 扩展写它）。
    @State var timelineShot: Shot?
    @State var similarShot: Shot?
    /// 单张重命名只有这一套输入框：右键和 F2 都汇入这里（+Card 扩展写它）。
    @State var renameTarget: Shot?
    @State var renameName = ""
    /// 仅图库入口接受图片拖放；其它固定范围不能把新图导入后藏在范围外。
    @State private var isImportDropTargeted = false
    @State var hasReportedFirstPage = false
    @State var metadataGeneration = 0

    // MARK: 宽度派生状态
    //
    // 这两个是全部的「宽度派生状态」，都住在**网格自己**这一层（历史上它们在
    // GalleryView 里，那是三栏的共同父层 —— 于是拖 NavigationSplitView 的分隔条
    // 每一帧都会重算 GalleryView.body，把侧边栏和详情栏一起拖下水。见 `widthReader`）。

    /// 网格列数。**离散量**：拖分隔条时只在跨阈值那一下变一次，
    /// 中间的几十帧一次 state 都不写 → GalleryGrid.body 也就不重算。
    /// 默认 4 = 默认窗宽（900）在默认缩放档（200）下的列数，首帧不跳。
    @State private var columnCount = 4

    /// 瀑布模式的**数值**列宽（网格模式不用，见 `gridItems`）。
    @State private var waterfallColumnWidth: CGFloat = 200

    // MARK: 版面常量
    //
    // 这四个数同时出现在「列宽数学」和「padding」两处，所以必须是同一份常量 ——
    // 两边各写一个字面量，改一处忘一处就会横向溢出或者最后一行被工具条压住。

    /// 网格内容的左右内缩。取 `DS.s2`(8) 是为了和 `GalleryPageHeader` 对齐
    ///（那一行由 GalleryView 加了 `.padding(.horizontal, DS.s2)`）：卡片已经没有
    /// 卡面了，图片的左边界**就是**内容的左边界，大标题和第一张图必须落在同一条竖线上。
    /// 旧值是 `DS.s4`(16)，那时候图片还缩在卡面里面 4pt，视觉左边界正好对得上。
    private static let contentInset: CGFloat = DS.s2

    /// 网格内容底部要让出的高度 = 工具条高 + 它离网格底边的距离 + 一档呼吸位。
    /// 悬浮工具条**不占布局位置**（它压在内容之上），少了这一档最后一行会被盖住。
    /// 工具条尺寸常量在 `GalleryFloatingToolbar`（同一份，两边不各写一个字面量）。
    private var contentBottomInset: CGFloat {
        chrome.showsFloatingToolbar ? GalleryFloatingToolbar.barHeight + 2 * DS.s3 : DS.s5
    }

    /// 列数由**外层稳定宽度**显式算出，绝不用 `.adaptive` ——
    /// 接实体鼠标时 macOS 显示常驻滚动条：内容超高 → 滚动条挤窄内容区 →
    /// adaptive 重排少一列 → 内容变矮 → 滚动条消失 → 变宽 → 翻回来……
    /// 自持振荡，表现为尾部卡片无输入也一直闪。列数只看外层宽度就稳了。
    private func resolvedColumnCount(for width: CGFloat) -> Int {
        var count = max(1, Int((width - 2 * Self.contentInset + DS.s4) / (zoom + DS.s4)))
        // 常驻滚动条那 16pt 的保护**留在列数公式里**：滚动条一出会把最后一列
        // 挤到明显窄于缩放档（< 60%）时，主动少排一列 —— 由我们显式决定，
        // 而不是让布局自己去反推（那就是上面那场振荡）。
        let usable = width - 2 * Self.contentInset - 16 - CGFloat(count - 1) * DS.s4
        if usable < CGFloat(count) * zoom * 0.6 { count = max(1, count - 1) }
        return count
    }

    /// 网格模式的列：**固定列数** × `.flexible`，列宽交给 SwiftUI 平分。
    ///
    /// ⚠️ `.flexible` **不是**退回 `.adaptive`，两者的区别就是上面那场事故的成因：
    ///   · `.adaptive` 自己从**可用宽度反推列数** —— 可用宽度含滚动条挤压，
    ///     于是「列数 → 内容高度 → 滚动条 → 可用宽度 → 列数」闭成一个环。
    ///   · `.flexible` **不碰列数**：列数是 `resolvedColumnCount(for:)` 从外层
    ///     稳定宽度算好的常量，它只负责把这几列拉开填满。滚动条出没带来的
    ///     十几点宽度抖动只会让列宽微变、**列数不变**，环断了，是良性的。
    /// 换成 `.flexible` 的收益：列宽不再是需要每帧写进 @State 的数值，
    /// 宽度派生状态收缩成一个离散的列数（见 `applyMetrics`）。
    ///
    /// minimum 用 80（老的 `itemWidth` 下限同一个数）而不是 zoom：
    /// `.flexible` 的 minimum 是硬下限，填 zoom 会在窄窗口下撑出横向溢出。
    private var gridItems: [GridItem] {
        Array(
            repeating: GridItem(.flexible(minimum: 80), spacing: DS.s4),
            count: max(1, columnCount)
        )
    }

    /// 瀑布模式的数值列宽。自定义 `Layout` 拿不到「交给 SwiftUI 拉伸」这条路
    /// （它必须自己摆位置），所以这一份数值躲不掉 —— 但可以把抖动**量化**掉：
    /// 向下取整到 4pt 的整数倍。
    ///
    /// 用量化而不是「变化超过阈值才写」：量化是「宽度 → 列宽」的纯函数，
    /// 同一个窗口宽度永远得到同一个列宽；阈值法带滞后，结果取决于拖动路径，
    /// 同样的窗宽可能停在不同列宽上，换个模式重新量取时还会跳一下。
    /// 代价是右侧最多多留 4pt × 列数的空白 —— 列从左边界起排（`.leading`），
    /// 富余全落在右侧，和滚动条预留的那 16pt 是同一侧、同一种留白。
    ///
    /// **向下**取整而不是四舍五入，且这里保留 16pt 的滚动条预留：
    /// WaterfallLayout 的自然宽度超过提案时会横向溢出（它故意不从 proposal
    /// 反推），列宽宁可小几点也不能大。
    private func quantizedWaterfallColumnWidth(for width: CGFloat, columns: Int) -> CGFloat {
        let usable = width - 2 * Self.contentInset - 16 - CGFloat(columns - 1) * DS.s4
        let raw = usable / CGFloat(max(1, columns))
        return max(80, (raw / DS.s1).rounded(.down) * DS.s1)
    }

    /// 键盘导航拿到的列数。瀑布模式各列行高不齐，「上下 = ±列数」的网格假设失效 ——
    /// 报 1，上下键退化为顺序前后（和左右一致）。
    private var keyboardColumnCount: Int {
        layoutMode == .waterfall ? 1 : columnCount
    }

    /// destination 的最终可见集合（+Card / +Data 扩展也读它）。
    /// 精确搜索和语义搜索共用同一个 store 数据源；
    /// `runSemanticSearch` 已按当前固定筛选
    /// 约束候选，所以网格、键盘和批量操作不会各自维护第二份结果。
    var visibleShots: [Shot] {
        presentation.displayShots(fallback: store.shots)
    }

    var body: some View {
        // 标准样式的工具条压在内容之上，所以仍用 ZStack；图库面板样式不画它，
        // 但共用同一棵网格与选择逻辑。
        ZStack(alignment: .bottom) {
            if visibleShots.isEmpty {
                emptyState
            } else {
                grid
            }

            if chrome.showsFloatingToolbar {
                GalleryFloatingToolbar(
                    viewModel: viewModel,
                    visibleCount: visibleShots.count,
                    layoutMode: $layoutMode,
                    zoom: $zoom
                )
            }
        }
        // ⚠️ 这里**故意不再铺** L0 画布（原来是一层不透明的 `underPageBackgroundColor`）。
        // 设计稿里中间区域直接坐在窗口底色上（卡片浮在深底上，没有卡面也没有画布纸）。
        // 旧注释给出的三条理由逐条核对，现在一条都不成立：
        //
        //  1. 「几百张缩略图不该铺在桌面模糊上，且白付一份 behind-window 采样成本」
        //     —— 这条的前提是网格底下真有 behind-window 材质。现在网格底下是
        //     `Color(nsColor: DS.windowBase)`（GalleryView 铺的**不透明**窗口底色，
        //     窗口本身也没开 `isOpaque = false`）。不透明这条硬要求由那一层满足，
        //     这里再铺一层只是同一件事做两遍，多一个不必要的图层。
        //
        //  2. 「铺在外层让空态也有同一块底，否则筛不到结果时会露出窗口底色，
        //     和有内容时不是一个灰」—— 现在有内容和空态露出的**都是**窗口底色，
        //     同一个灰是结构保证的，不再需要靠补一层来对齐。这条理由直接反转了。
        //
        //  3. 「ScrollView 那一份要盖住工具栏底下的 52pt，否则 unified 工具栏的材质
        //     采样到窗口底色、和网格差一档灰」—— unified 工具栏在外壳改版里整个
        //     取消了（顶栏改成自绘的 GalleryTopBar，它自己不画背景块）。既没有工具栏
        //     材质要采样，网格的帧也不再伸到窗口顶。这条理由随工具栏一起消失。
        //
        // 唯一必须留下的是 `grid` 里的 `.scrollContentBackground(.hidden)`：
        // macOS 的 ScrollView 自带一层不透明 `windowBackgroundColor`，不关掉的话
        // 它会盖住窗口底色，露出第二种灰 —— 那和画布归属无关，是 ScrollView 自己的默认值。
        //
        // 宽度感知：测量点是**本视图的根帧**（= 网格列的容器帧，滚动条在它内部），
        // 和它历史上待的位置（GalleryView 里 `.background(gridWidthReader)`）是同一层几何，
        // 只是写的 state 从三栏共同父层挪进了网格子树。
        .onAppear { MouseModifierCache.shared.install() }
        .background(widthReader)
        .dropDestination(for: URL.self) { urls, _ in
            guard scope == .library else { return false }
            guard urls.contains(where: ImageImportCoordinator.supports) else { return false }
            viewModel.reset()
            imageImporter.enqueue(urls)
            return true
        } isTargeted: { targeted in
            isImportDropTargeted = targeted && scope == .library
        }
        .overlay {
            if isImportDropTargeted {
                RoundedRectangle(cornerRadius: DS.radiusPanel, style: .continuous)
                    .fill(DS.accentFillDropTarget)
                    .overlay {
                        Label("松开以导入图片", systemImage: "square.and.arrow.down")
                            .font(.headline)
                            .padding(.horizontal, DS.s4)
                            .padding(.vertical, DS.s3)
                            .background(.regularMaterial, in: Capsule())
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: DS.radiusPanel, style: .continuous)
                            .stroke(DS.accent, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    }
                    .allowsHitTesting(false)
            }
        }
        // 列数是键盘导航（上下键 = ±列数）唯一需要知道的东西，网格算好直接喂。
        // 空列表时网格不渲染，这里也照样上报（值无害，且列表回来时不用等首帧）。
        .onChange(of: keyboardColumnCount, initial: true) { _, count in
            keyboard?.gridColumnCount = count
        }
        .task(id: GalleryGridSnapshotKey(
            sessionGeneration: sessionLifecycle.generation,
            presentationRevision: presentation.revision,
            shots: visibleShots
        )) {
            await refreshGridSnapshot()
        }
        .task(id: selection.generation) {
            await refreshSelectedCollectionMemberships()
        }
        .onReceive(store.libraryDidChangePublisher) {
            // 相同 ID 的标题/属性变化不会改变 task identity，由库存完成信号补这一轮。
            sessionLifecycle.runReplacing(.gridSnapshot) {
                await refreshGridSnapshot(forceFullMetadata: true)
            }
        }
        .onReceive(sessionLifecycle.$isActive.removeDuplicates()) { isActive in
            if !isActive { releaseSessionDerivedSnapshots() }
        }
        .onChange(of: selection.pendingRenameID) { _, requestedID in
            guard let requestedID else { return }
            defer { selection.pendingRenameID = nil }
            guard let shot = visibleShots.first(where: { $0.id == requestedID })
                    ?? store.shots.first(where: { $0.id == requestedID })
            else { return }
            beginRename(shot)
        }
        .sheet(item: $timelineShot) { TimelineSheet(shot: $0) }
        .sheet(item: $similarShot) { SimilarShotsSheet(shot: $0) }
        .alert("修改图库名称", isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )) {
            TextField("显示名称", text: $renameName)
            Button("取消", role: .cancel) { renameTarget = nil }
            if renameTarget?.customTitle != nil {
                Button("恢复自动名称") { commitRename(nil) }
            }
            Button("保存") { commitRename(renameName) }
        } message: {
            Text("最多 80 个字符；只修改图库元数据，不会重命名真实原图。")
        }
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
        guard !batchActivity.isBusy else { return }
        let idSet = Set(ids)
        let display = visibleShots
        let anchorIndex = display.firstIndex { $0.id.map(idSet.contains) ?? false }
        // 直接按全量 ID 单事务删除；后续分页尚未加载成 Shot 也不能漏。
        store.delete(shotIDs: ids)
        let remaining = visibleShots.filter { shot in
            shot.id.map(idSet.contains) != true
        }
        if let anchorIndex, !remaining.isEmpty {
            selection.select(only: remaining[min(anchorIndex, remaining.count - 1)].id)
        } else {
            selection.select(only: nil)
        }
    }

    /// 宽度感知。落在**网格自己**这一层：拖 NavigationSplitView 的分隔条时，
    /// 每帧变化的宽度只写进这棵子树的 state，侧边栏与详情栏的 body 不跟着重算。
    ///
    /// 测量点必须留在这个容器帧上（滚动条在它**内部**），
    /// **绝不能挪进 ScrollView 的内容里** —— 那是滚动条挤压振荡的来源
    ///（见 `resolvedColumnCount(for:)` 与 WaterfallLayout 顶部的注释）。
    private var widthReader: some View {
        GeometryReader { proxy in
            Color.clear
                .onChange(of: proxy.size.width, initial: true) { _, width in
                    applyMetrics(width: width)
                }
                // 缩放滑杆和模式切换不改容器宽度，但都会改列数 / 列宽 ——
                // 在这里各补一遍（proxy 给的是当前帧的宽度）。
                .onChange(of: zoom) { _, _ in applyMetrics(width: proxy.size.width) }
                .onChange(of: layoutMode) { _, _ in applyMetrics(width: proxy.size.width) }
        }
    }

    /// 宽度 → 状态。**值没变就不写**，这是本文件里唯一挡住「每帧失效」的地方。
    private func applyMetrics(width: CGFloat) {
        guard width > 0 else { return }
        let count = resolvedColumnCount(for: width)
        if count != columnCount { columnCount = count }
        // 数值列宽只有瀑布模式读（网格模式交给 `.flexible`），
        // 所以网格模式下连量化后的那几次写也省掉。
        guard layoutMode == .waterfall else { return }
        let columnWidth = quantizedWaterfallColumnWidth(for: width, columns: count)
        if columnWidth != waterfallColumnWidth { waterfallColumnWidth = columnWidth }
    }

    private var grid: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if layoutMode == .waterfall {
                    waterfall
                } else {
                    // 单层 LazyVGrid + Section：嵌套懒容器（LazyVStack>LazyVGrid）
                    // 在内容尾部有已知的重排抖动，扁平化后吸顶头由网格自己管。
                    LazyVGrid(
                        columns: gridItems,
                        alignment: .leading,
                        spacing: DS.s4,
                        pinnedViews: [.sectionHeaders]
                    ) {
                        ForEach(sections) { section in
                            Section {
                                ForEach(section.shots) { shot in
                                    card(for: shot, height: zoom * 0.68)
                                        .onAppear { loadMoreIfNeeded(reaching: shot) }
                                }
                            } header: {
                                sectionHeader(for: section)
                            }
                        }
                    }
                    .padding(.horizontal, Self.contentInset)
                    .padding(.bottom, contentBottomInset)
                }
            }
            // ScrollView 在 macOS 上自带一层不透明底（windowBackgroundColor）。
            // **画布交还窗口底色之后这一行反而更要紧了**：以前它盖住的是我们自己铺的
            // 画布色（两种灰打架），现在它会直接盖住 `DS.windowBase`，
            // 中栏就成了一块和窗口不同色的方纸。
            .scrollContentBackground(.hidden)
            //
            // ⚠️ 这里**故意不挂** `.scrollEdgeMask(topInset:)`。
            //
            // 旧注释里的第一条理由（unified 工具栏给 NSScrollView 设了
            // contentInsets.top = 52）随工具栏取消一起失效了，但**结论不变**，
            // 因为第二条理由是结构性的、与工具栏无关：
            //   吸顶分组头 pin 的位置 = ScrollView 帧的顶边，
            //   而 mask 渐变带的起点也是 ScrollView 帧的顶边 —— 两者永远重合。
            // 于是渐变带整条压在吸顶头上，把分组头自己淡成半透明（实测：28pt 渐变
            // 让 .title3 的分组头顶部 2/3 透出底下的底色）。
            // 规格要的是「卡片滑进标题时化开」，不是「标题自己化没」。
            //
            // 冻结的 `ScrollEdgeMask` 只有 topInset、没有「渐变带起点下移」的参数，
            // 在有 pinnedViews 的容器上无解 —— 这条已写进交付报告，等底座补 API。
            // 顶部边缘的「化开」当前由逐卡 `scrollDepth()` 承担（见 card(for:)）。

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
        LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
            ForEach(sections) { section in
                Section {
                    WaterfallLayout(
                        columnCount: columnCount,
                        columnWidth: waterfallColumnWidth,
                        spacing: DS.s4
                    ) {
                        ForEach(section.shots) { shot in
                            card(
                                for: shot,
                                height: waterfallHeight(
                                    for: shot,
                                    columnWidth: waterfallColumnWidth
                                )
                            )
                            .onAppear { loadMoreIfNeeded(reaching: shot) }
                        }
                    }
                    .padding(.bottom, DS.s4)
                } header: {
                    sectionHeader(for: section)
                }
            }
        }
        .padding(.horizontal, Self.contentInset)
        .padding(.bottom, contentBottomInset)
    }

    /// 瀑布卡片的缩略图高度 = **可用图宽** / 图片长宽比。
    /// 尺寸元数据（pixelWidth/Height）建库时就有，不用解码图片。
    /// 缩略图生成是等比缩放（ImageCodec.resized），CachedImage 的 .fit
    /// 在这个高度下正好铺满，不裁切也不留边。
    ///
    /// 可用图宽 = **整个列宽**。卡面取消之后缩略图不再内缩（旧版是卡面内左右各 4pt，
    /// 为的是同心圆角 10 − 4 = 6），图片自己就是单元格的左右边界。
    /// 这个数必须和 `ShotCard` 的实际图宽严格一致：多算几点，`.fit` 之下就会在
    /// 上下各留一条空边 —— 瀑布模式「等宽不裁切、完整贴合」的全部意义就在于没有这条边。
    private func waterfallHeight(for shot: Shot, columnWidth: CGFloat) -> CGFloat {
        let pixelWidth = CGFloat(max(1, shot.pixelWidth))
        let pixelHeight = CGFloat(max(1, shot.pixelHeight))
        return max(1, columnWidth) * pixelHeight / pixelWidth
    }

    /// 吸顶分组标题：「今天 · 12」，垫 .bar 材质盖住滚过的卡片。
    ///
    /// 不再加水平内缩：标题要和第一张卡片的**图片左边界**对齐（卡片没有卡面了，
    /// 图片边界就是单元格边界）。材质带宽度 = 网格内容宽度，正好盖住滚上来的卡片。
    private func sectionHeader(for section: ShotSection) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.s2) {
            Text(section.title)
                .font(.title3.weight(.semibold))
            Text("· \(section.shots.count)")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.vertical, DS.s2)
        // 用当前容器的实色盖住滚上来的卡片，而不是 `.bar` 材质。
        // 材质在浅色下会渲染成一条横贯内容区的白带，比周围还亮 ——
        // 分组头是个标签，不该是屏幕上最亮的一条。同色不透明底同样能盖住内容，
        // 而且和中间区域本来就坐在窗底上这件事一致（网格没有自己的画布）。
        .background(sectionHeaderFill)
    }

    private var sectionHeaderFill: Color {
        chrome == .libraryPanel ? DS.panelFill(.resting) : Color(nsColor: DS.windowBase)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(emptyTitle, systemImage: emptyIcon)
        } description: {
            Text(emptyDescription)
        } actions: {
            if hasActiveFilter {
                Button("清除筛选") { scope.clearTransientState(in: viewModel) }
            } else if scope.showsStartCaptureAction {
                HStack {
                    Button("开始截图") { CaptureCoordinator.shared.begin() }
                        .buttonStyle(.borderedProminent)
                    Button("导入图片…") { chooseImagesToImport() }
                        .buttonStyle(.bordered)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func chooseImagesToImport() {
        guard let urls = SystemNavigator.chooseImageFiles(), !urls.isEmpty else { return }
        viewModel.reset()
        imageImporter.enqueue(urls)
    }

    /// 空态是「筛出来的空」还是「真的一张都没有」——决定给哪个按钮。
    private var hasActiveFilter: Bool {
        scope.hasClearableState(
            searchText: viewModel.searchText,
            filter: viewModel.filter,
            hasSemanticResults: viewModel.semanticMode && viewModel.semanticResults != nil
        )
    }

    private var emptyTitle: String {
        if viewModel.semanticMode && viewModel.semanticResults != nil { return "没有语义匹配的结果" }
        if viewModel.searchText.isEmpty, let scopedTitle = scope.emptyTitle { return scopedTitle }
        return viewModel.searchText.isEmpty ? "还没有截图" : "没有匹配的结果"
    }

    private var emptyIcon: String {
        if viewModel.semanticMode && viewModel.semanticResults != nil { return "sparkle.magnifyingglass" }
        if viewModel.searchText.isEmpty, let scopedIcon = scope.emptyIcon { return scopedIcon }
        return viewModel.searchText.isEmpty ? "photo.on.rectangle.angled" : "magnifyingglass"
    }

    private var emptyDescription: String {
        if viewModel.semanticMode && viewModel.semanticResults != nil {
            return "截图可能还没完成向量分析，或换种描述再试（英文效果最好）"
        }
        if viewModel.searchText.isEmpty, let scopedDescription = scope.emptyDescription {
            return scopedDescription
        }
        return viewModel.searchText.isEmpty ? "按 ⌃⌘A 开始截图" : "换个关键词，或清除侧边栏筛选"
    }
}

#if DEBUG
#Preview {
    // 轻量预览：FakeShotStore.preview 零 GRDB、零落盘，6 张样本直接可用。
    // 此处不直接渲染 GalleryGrid（其 store 为 ShotStore 真库），而是用预览数据
    // 验证 FakeShotStore 的轻量实现在 Preview 环境下可正常构造与读取。
    let store = FakeShotStore.preview
    VStack(alignment: .leading, spacing: 8) {
        Text("GalleryGrid · FakeShotStore 预览").font(.headline)
        Text("\(store.shots.count) 张样本 · 收藏 \(store.favoriteIDs.count) · 标签 \(store.allTags().count)")
            .font(.subheadline).foregroundStyle(.secondary)
        ForEach(store.shots) { shot in
            Text(shot.windowTitle ?? shot.appName ?? "Untitled").font(.caption)
        }
    }
    .padding()
    .frame(width: 320)
}
#endif
