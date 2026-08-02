import SwiftUI
import AppKit

// MARK: - 网格
//
// 图库中栏：时间分组（ShotSection）、网格 / 瀑布两种显示模式（GalleryLayoutKind）、
// 稳定列宽数学、卡片装配与右键菜单、空态与底部悬浮工具条，
// 以及全图库唯一的那套删除确认框。
//
// 2026-07 改版的两件结构性变化：
//   1. **画布交还窗口底色**（原来这里铺一层不透明的 `underPageBackgroundColor`）。
//      逐条核对见 `body` 上的注释 —— 三条旧理由现在一条都不成立了。
//   2. **底栏从贴底通栏变成居中悬浮胶囊**（设计稿 §5），因此它不再自动为内容
//      占位，网格内容底部要显式让出 `contentBottomInset`。

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

struct GalleryGrid: View {

    @ObservedObject private var store = ShotStore.shared
    @ObservedObject private var selection = GallerySelection.shared
    /// 只为一个开关订阅：逐卡滚动深度（`galleryScrollDepth`）。
    /// 设置项的变更频率是「用户偶尔点一下」，用它换「关掉开关立刻生效」是划算的。
    @ObservedObject private var settings = AppSettings.shared

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

    /// 按时间段分好组的结果，随 store.shots 变化重算一次。
    @State private var sections: [ShotSection] = []
    /// shotID → 分类名。分组时一条 IN 查询批量拉好，卡片只收结果，保持不订阅 store。
    @State private var categoriesByShot: [Int64: String] = [:]
    /// 修订数 > 1（真的标注过）的截图 ID，卡片右下角角标用。同样批量查好下发。
    @State private var annotatedIDs: Set<Int64> = []
    /// 右键菜单打开的时间线 / 相似 sheet。
    @State private var timelineShot: Shot?
    @State private var similarShot: Shot?

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

    /// 悬浮工具条：设计稿 §5 的 540 × 56。宽度是**上限**不是定值 ——
    /// 窗口收到最小宽（1000）时中栏只剩 350 上下，写死 540 会横向溢出。
    private static let toolbarWidth: CGFloat = 540
    private static let toolbarHeight: CGFloat = 56

    /// 网格内容底部要让出的高度 = 工具条高 + 它离网格底边的距离 + 一档呼吸位。
    /// 悬浮工具条**不占布局位置**（它压在内容之上），少了这一档最后一行会被盖住。
    private static let contentBottomInset: CGFloat = toolbarHeight + 2 * DS.s3

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

    /// 网格内容的重算触发器：模式切换或数据变化都要重新分组。
    private struct GridKey: Equatable {
        let semanticMode: Bool
        let shots: [Shot]
    }

    var body: some View {
        // 工具条**压在内容之上**（设计稿 §5：居中悬浮胶囊，不是贴底通栏），
        // 所以是 ZStack 而不是 VStack。它不占布局位置，内容底部的让位见
        // `contentBottomInset`。
        ZStack(alignment: .bottom) {
            if store.displayShots.isEmpty {
                emptyState
            } else {
                grid
            }

            floatingToolbar
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
        .background(widthReader)
        // 列数是键盘导航（上下键 = ±列数）唯一需要知道的东西，网格算好直接喂。
        // 空列表时网格不渲染，这里也照样上报（值无害，且列表回来时不用等首帧）。
        .onChange(of: keyboardColumnCount, initial: true) { _, count in
            GalleryKeyboard.shared.gridColumnCount = count
        }
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
                                }
                            } header: {
                                sectionHeader(for: section)
                            }
                        }
                    }
                    .padding(.horizontal, Self.contentInset)
                    .padding(.bottom, Self.contentBottomInset)
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
                        }
                    }
                    .padding(.bottom, DS.s4)
                } header: {
                    sectionHeader(for: section)
                }
            }
        }
        .padding(.horizontal, Self.contentInset)
        .padding(.bottom, Self.contentBottomInset)
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
        // 用**窗口底色**盖住滚上来的卡片，而不是 `.bar` 材质。
        // 材质在浅色下会渲染成一条横贯内容区的白带，比周围还亮 ——
        // 分组头是个标签，不该是屏幕上最亮的一条。同色不透明底同样能盖住内容，
        // 而且和中间区域本来就坐在窗底上这件事一致（网格没有自己的画布）。
        .background(Color(nsColor: DS.windowBase))
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
        // 用 `onDrag` 而不是 `.draggable(_:)`，理由是**接收方兼容性**：
        //
        // `.draggable` 配 `FileRepresentation` 交出去的是「文件承诺」（promise）。
        // 访达、邮件认它，但**浏览器的上传控件和多数 Office 应用只收磁盘上
        // 真实存在的文件 URL**，拿到承诺就当没有，表现为「拖过去没反应」。
        // 暂存卡片一直能拖进这些地方，正是因为它走 AppKit 的
        // `NSDraggingItem(pasteboardWriter: url as NSURL)`，天生就是真 URL。
        //
        // `onDrag` 的闭包在**拖拽真正开始时**才执行（不是 body 求值时），
        // 所以「载荷必须廉价」那条红线依然守得住 —— 渲染整张 PNG 一次拖拽只跑一次，
        // 而不是每张可见卡片每帧跑一次（那是当年拖垮图库滚动的事故）。
        .onDrag {
            NSItemProvider(contentsOf: dragFileURL(for: shot)) ?? NSItemProvider()
        }
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
        Button("复制 \(count) 张图片") {
            GalleryBatch.copyImages(shots)
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

    // MARK: - 底部悬浮工具条（设计稿 §5）

    /// 居中悬浮的圆角胶囊，不再是贴底通栏。左边显示模式分段控件、右边缩放滑杆，
    /// 中间留空（只有语义搜索状态会临时占用那段空白，见 `semanticStatus`）。
    ///
    /// 三个落地取舍：
    ///
    /// 1. **圆角用 `DS.radiusPanel`(14) 而不是设计稿的 16。** DS 的圆角阶梯是
    ///    6 / 10 / 14 / 18 五档，没有 16 那一档，而 GalleryShell 的 `floatingPanel`
    ///    文档本来就写着「小面板（图标轨、悬浮胶囊）用 `DS.radiusPanel`(14)」——
    ///    为了 2pt 新开一档 token 不值得（而且 DesignTokens 这一轮不许改）。
    ///
    /// 2. **`level: .overlay`。** 这块是压在内容之上的，不是坐在窗口底色上：
    ///    底色亮一档、浅色下阴影更重，两者都是「它离用户更近」的线索。
    ///
    /// 3. **只有两个图标，不是设计稿画的三个。** 理由见 `layoutPicker`。
    private var floatingToolbar: some View {
        HStack(spacing: DS.s3) {
            layoutPicker
            Spacer(minLength: DS.s2)
            semanticStatus
            Spacer(minLength: DS.s2)
            zoomSlider
        }
        .padding(.horizontal, DS.s4)
        .frame(height: Self.toolbarHeight)
        .frame(maxWidth: Self.toolbarWidth)
        .floatingPanel(radius: DS.radiusPanel, level: .overlay)
        // 12 + GalleryView 给中栏的 12(`DS.Shell.windowMargin`) = 距窗底 24（设计稿）。
        .padding(.bottom, DS.s3)
    }

    /// 显示模式分段控件。
    ///
    /// **设计稿画了三个图标（网格 / 分栏 / 列表），这里只有两个** —— 本项目真实存在的
    /// 布局就是网格与瀑布两种，为了凑数量摆一个点了没反应（或者和网格几乎一样）的
    /// 第三个图标是欺骗性 UI，比少一个图标糟得多。
    ///
    /// 「真的实现一个列表模式」在这一轮也做不成：`GalleryLayoutKind` 定义在
    /// `GalleryTopBar.swift`，加一个 case 会同时打断那个文件里 `symbol` / `title`
    /// 两个穷尽 switch，而那个文件本轮不在可改范围内。等它开放时再补，
    /// 届时顶栏的分段控件会自动多出一格（它是 `ForEach(allCases)` 驱动的）。
    ///
    /// 布局切换是「整片内容重排」，用 standard（0.35 / 0.85）：比系统默认的 0.55 利落，
    /// 又不像 micro 那样快到读不出内容是怎么挪的。动画包在 setter 的事务里而不是给网格
    /// 挂常驻 `.animation(value:)` —— 后者会让网格里任何一次尺寸变化（比如缩放滑杆）
    /// 都被顺带动画掉。
    private var layoutPicker: some View {
        Picker("显示模式", selection: Binding(
            get: { layoutMode },
            set: { newValue in
                withAnimation(DS.Motion.standard(reduced: reduceMotion)) { layoutMode = newValue }
            }
        )) {
            ForEach(GalleryLayoutKind.allCases, id: \.self) { kind in
                Image(systemName: kind.symbol).tag(kind)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help("网格：整齐等高，超出裁切；瀑布：等宽不裁切，完整显示长图")
    }

    /// 缩放滑杆：左端小图标、中间滑杆、右端大图标（设计稿 §5）。
    /// 两个图标是「更多列 / 更少列」的图示，不是按钮 —— 语义上它们是滑杆两端的标尺。
    private var zoomSlider: some View {
        HStack(spacing: DS.s2) {
            Image(systemName: "square.grid.3x3")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            // maxWidth 而不是 width：窗口窄到中栏只剩几百点时，滑杆先让位，
            // 而不是把分段控件挤出胶囊。
            Slider(value: $zoom, in: 140...320)
                .frame(maxWidth: 200)
                .controlSize(.small)
                .accessibilityLabel("缩略图大小")
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 13))
                .foregroundStyle(.tertiary)
        }
        .help("缩略图大小")
    }

    /// 语义搜索状态。设计稿的胶囊里没有这一段，但**它是唯一能报告「正在跑语义搜索」
    /// 的地方**，删不得（设计稿没画的功能不许删）。占的是两组控件之间那段留白 ——
    /// 平时空着，有话说时才出现，不改变两组控件的位置。
    ///
    /// 旧底栏那句「N 张截图」没有搬过来：`GalleryPageHeader` 的「N 个项目」是同一个
    /// `store.displayShots.count`，同屏两处报同一个数是冗余。
    @ViewBuilder
    private var semanticStatus: some View {
        if store.isSemanticSearching {
            HStack(spacing: DS.s2) {
                ProgressView().controlSize(.mini)
                Text("语义搜索中…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        } else if store.semanticMode, store.semanticResults != nil {
            Text("语义搜索：最相关的 \(store.displayShots.count) 张")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
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
    /// 拖拽用的成品 PNG 落到磁盘，返回它的 URL。
    ///
    /// **只在拖拽真正开始时调一次**（`onDrag` 的闭包），不是每帧。
    /// 重活集中在这：读原图 → 合成最新修订 → 编码 → 写临时文件；
    /// 目录复用暂存栏的拖拽临时目录，下次启动统一清理；渲染失败退回原图路径
    /// （拖出去的至少还是这张截图，只是没有标注）。
    private func dragFileURL(for shot: Shot) -> URL {
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

    // 这里曾经有个 `draggedIDs`：拖拽时携带「全部选中项的 ID」，
    // 供侧边栏「拖到标签上打标签」接收。那批投放目标在简化侧边栏时删掉了，
    // 这条应用内通道随之没有了消费方（连同 `ShotDragFile` / `ShotIDPayload`
    // 与那个自定义 UTType 一起移除）。将来要恢复拖放打标签，
    // 从 git 历史里取回即可 —— 那套载荷的廉价纪律有完整注释。

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

    /// 单张复制走与 ⌘C、批量菜单**同一份**实现（`GalleryBatch.copyImages`）——
    /// 复制的是成品（原图 + 最新修订的标注），三个入口不该有三种结果。
    private func copy(_ shot: Shot) {
        GalleryBatch.copyImages([shot])
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
