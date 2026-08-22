import SwiftUI
import AppKit

// MARK: - 相似截图
//
// 「查找相似」的结果 sheet 与它专用的结果卡片。
// 网格右键和详情栏「更多」菜单都从这里弹。

/// 「查找相似」结果。指纹距离在 ShotStore 里已算好并升序排好，这里只管展示。
///
/// 视觉语言和改版后的图库统一：**窗口底色打底 + 浮起的圆角卡片**
///（`DS.windowBase` + `floatingPanel`），标题行直接坐在底色上、结果网格装在卡片里。
///
/// 为什么不再是 `.popover` 材质 + 双层阴影：
///   · 这块 sheet 自己就是一个窗口，底下没有本 App 的内容可借 —— 材质只会
///     采样到自家的不透明底，白付一份模糊（同 GalleryShell 的取舍 1）；
///   · sheet 的投影由系统画，自绘的双层阴影落在自己的窗口里根本出不去边界；
///   · 顺带的好处：ReduceTransparency 不需要降级分支，本来就是实色。
/// 卡片的描边 / 浅色阴影 / 圆角全部由 `floatingPanel` 统一给出，这里不再手写 rim。
struct SimilarShotsSheet: View {
    let shot: Shot
    private let store: ShotStore

    init(shot: Shot, store: ShotStore = .shared) {
        self.shot = shot
        self.store = store
    }

    @Environment(\.dismiss) private var dismiss
    /// nil = 还在比对；空数组 = 比对完但没有可比的候选。
    @State private var results: [Shot]?

    var body: some View {
        ZStack {
            // 深底。sheet 的四角由系统裁，这一层只负责「面板之间露出的那层灰」。
            Color(nsColor: DS.windowBase)
                .ignoresSafeArea()

            VStack(spacing: DS.Shell.panelGap) {
                header
                resultsPanel
            }
            .padding(DS.Shell.windowMargin)
        }
        .frame(width: 640, height: 440)
        // 「比对中 → 结果」是整块面板的换面，属于大面积表面：走 ambient
        //（response 0.50、临界阻尼零过冲）。大面块动得慢才不晃眼；
        // ambient 本身就没有回弹，Reduce Motion 下也无需再降级。
        .animation(DS.Motion.ambient, value: results == nil)
        .task(id: shot.id) {
            results = await store.similarShots(to: shot)
        }
    }

    /// 标题行坐在窗口底色上（不进卡片）—— 卡片的边界本身就是「标题 / 结果区」
    /// 的分组线索，原来那条 Divider 因此不再需要。
    private var header: some View {
        HStack(spacing: DS.s2) {
            Label("相似截图", systemImage: "sparkles.rectangle.stack")
                .font(.headline)
            Spacer(minLength: 0)
            PanelCloseButton(label: "关闭") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, DS.s2)
    }

    private var resultsPanel: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // ScrollView 在 macOS 上会垫一层不透明的 windowBackgroundColor，
            // 不关掉会盖住卡片自己的底色（两种灰打架）。
            .scrollContentBackground(.hidden)
            .floatingPanel()
    }

    @ViewBuilder
    private var content: some View {
        if let results {
            if results.isEmpty {
                ContentUnavailableView(
                    "没有可比对的截图",
                    systemImage: "sparkles.rectangle.stack",
                    description: Text("其它截图还没完成特征分析，稍后再试")
                )
            } else {
                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 150, maximum: 210), spacing: DS.s3)],
                        spacing: DS.s4
                    ) {
                        ForEach(results) { result in
                            SimilarShotCard(shot: result, store: store)
                                .onTapGesture {
                                    // 定位类场景：清空多选后单选目标。
                                    GalleryWindowController.shared.selection.select(only: result.id)
                                    dismiss()
                                }
                        }
                    }
                    .padding(DS.s4)
                }
            }
        } else {
            ProgressView("正在比对特征指纹…")
        }
    }
}

/// 相似结果卡片：缩略图 + App 名 + 时间。刻意比 ShotCard 简单 ——
/// 结果按相似度排序本身就是提示，不展示精确距离数值。
///
/// 深度表达整个交给 `spatialCard`：填充 + 渐变描边 + 单层阴影 + 悬停抬升，
/// 一次给全。原来那圈「hover 时描边 0.08→0.3」的手写 overlay 因此删掉 ——
/// 同一件事没必要画两遍，而且它的两个不透明度都是拍脑袋来的。
private struct SimilarShotCard: View {
    let shot: Shot
    private let store: ShotStore

    init(shot: Shot, store: ShotStore = .shared) {
        self.shot = shot
        self.store = store
    }

    @State private var isHovering = false

    /// 同心圆角：卡片外 10、缩略图内缩 s1(4) → 内圆角 6（正好是 radiusSmall）。
    /// 旧代码写死的 8 既不同心也不在圆角阶梯上，拐角处的间隙会被掐细。
    private var thumbRadius: CGFloat {
        DS.radiusInner(outer: DS.radiusCard, inset: DS.s1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.s2) {
            ZStack {
                RoundedRectangle(cornerRadius: thumbRadius, style: .continuous)
                    .fill(DS.insetSurface)
                CachedImage(url: store.thumbnailURL(for: shot), key: shot.sha256)
                    .clipShape(RoundedRectangle(cornerRadius: thumbRadius, style: .continuous))
            }
            .frame(height: 100)

            VStack(alignment: .leading, spacing: 1) {
                Text(shot.primaryDisplayName)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                Text(shot.capturedAt, format: .dateTime.month().day().hour().minute())
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            // 底部多 4pt：文字块四边等距时视觉上会偏下（descender 贴边），
            // 这是排版上的老规矩，不是随手加的。
            .padding(.bottom, DS.s1)
        }
        // s1(4) 的内缩既给缩略图留出卡片边缘，也让上面的同心公式落在 radiusSmall 上。
        .padding(DS.s1)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .spatialCard(SpatialCardState(isHovering: isHovering))
    }
}
