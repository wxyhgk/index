import SwiftUI

// MARK: - 相似截图
//
// 「查找相似」的结果 sheet 与它专用的结果卡片。
// 网格右键和详情栏「更多」菜单都从这里弹。

/// 「查找相似」结果。指纹距离在 ShotStore 里已算好并升序排好，这里只管展示。
///
/// 这是全项目唯一的 L3 浮层实例（见规格 §1）：`.popover` 材质 + `.withinWindow`
/// 混合 + `DS.radiusPanel`(14) 圆角 + **双层阴影**（宽软的环境光 + 短锐的直接光）。
/// 双层阴影只有 L3 配用 —— 它等于两份离屏合成，网格里几百张卡片各来两份是性能自杀，
/// 而浮层同屏通常只有一个，成本有界。
/// 材质选 `.popover` 而不是 `.hudWindow`：这块面板装的是可读的图文网格，
/// hudWindow 是给瞬时 HUD 的重着色材质，压在正文上会吃掉文字对比。
struct SimilarShotsSheet: View {
    let shot: Shot

    @Environment(\.dismiss) private var dismiss
    /// 边缘高光（rim）和阴影都要按外观分流 —— 深色靠亮度和顶边接光，浅色靠阴影。
    @Environment(\.colorScheme) private var scheme
    /// 降低透明度时 rim 的加法混合要退回 `.normal`，否则在实色底上会烧出一道白边。
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
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
            .padding(DS.s3)

            // 这条 Divider 保留：头部和内容在**同一块材质**上，没有材质边界可用，
            // 它是这里唯一能读出「标题栏 / 结果区」分组的线索 —— 功能，不是装饰。
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
                            columns: [GridItem(.adaptive(minimum: 150, maximum: 210), spacing: DS.s3)],
                            spacing: DS.s4
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
                        .padding(DS.s4)
                    }
                }
            } else {
                ProgressView("正在比对特征指纹…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 640, height: 440)
        // 「比对中 → 结果」是整块面板的换面，属于大面积表面：走 ambient
        //（response 0.50、临界阻尼零过冲）。大面块动得慢才不晃眼；
        // ambient 本身就没有回弹，Reduce Motion 下也无需再降级。
        .animation(DS.Motion.ambient, value: results == nil)
        .glassPanel(.popover, blending: .withinWindow, radius: DS.radiusPanel)
        // 边缘高光：浅色是「整体暗一档、底边更暗」的发丝线，深色是「顶边接光」。
        // 浮层浮在别的内容之上，没有这一圈边，两种外观下面板都会和底下糊在一起。
        .overlay {
            let rim = DS.rim(.floating, scheme, hovering: false)
            RoundedRectangle(cornerRadius: DS.radiusPanel, style: .continuous)
                .strokeBorder(rim.gradient, lineWidth: rim.lineWidth)
                .blendMode(reduceTransparency ? .normal : rim.blend)
                .allowsHitTesting(false)
        }
        // 混合模式必须有 compositingGroup 兜边界，否则会和兄弟视图混合；
        // 它也顺便让两层阴影都基于同一个已合成的形状去画。
        .compositingGroup()
        .shadow(color: ambientShadow.color, radius: ambientShadow.radius, y: ambientShadow.y)
        .shadow(color: keyShadow.color, radius: keyShadow.radius, y: keyShadow.y)
        .task(id: shot.id) {
            results = await ShotStore.shared.similarShots(to: shot)
        }
    }

    /// 环境光：宽而软，交代「这块面板离底下很远」。
    private var ambientShadow: DS.Shadow { DS.shadow(.floating, scheme) }
    /// 直接光：短而锐，贴着边缘把轮廓咬出来。只有 L3 配叠这一层。
    private var keyShadow: DS.Shadow { DS.shadowKey(scheme) }
}

/// 相似结果卡片：缩略图 + App 名 + 时间。刻意比 ShotCard 简单 ——
/// 结果按相似度排序本身就是提示，不展示精确距离数值。
///
/// 深度表达整个交给 `spatialCard`：填充 + 渐变描边 + 单层阴影 + 悬停抬升，
/// 一次给全。原来那圈「hover 时描边 0.08→0.3」的手写 overlay 因此删掉 ——
/// 同一件事没必要画两遍，而且它的两个不透明度都是拍脑袋来的。
private struct SimilarShotCard: View {
    let shot: Shot

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
                    .fill(.quaternary.opacity(0.5))
                CachedImage(url: ShotStore.shared.thumbnailURL(for: shot), key: shot.sha256)
                    .clipShape(RoundedRectangle(cornerRadius: thumbRadius, style: .continuous))
            }
            .frame(height: 100)

            VStack(alignment: .leading, spacing: 1) {
                Text(shot.appName ?? "未知 App")
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
