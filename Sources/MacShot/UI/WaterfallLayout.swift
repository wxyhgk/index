import SwiftUI

/// Eagle 式等宽多列瀑布布局：列宽固定、卡片不裁切，逐个贪心放进当前最矮的列。
///
/// 列宽 / 列数由外部显式传入 —— 沿用 GalleryGrid 的稳定列宽计算，
/// **不从 proposal 反推**：接实体鼠标时常驻滚动条会挤窄内容区，
/// 从内容宽度反推列数会形成「重排 → 高度变化 → 滚动条出没 → 再重排」的自持振荡。
/// 列数只看外层稳定宽度，这里只负责摆。
///
/// 传进来的 `columnWidth` 是**量化过**的（4pt 网格，向下取整，且已扣掉常驻滚动条的
/// 16pt 预留，见 `GalleryGrid.quantizedWaterfallColumnWidth`）：网格模式的列宽可以
/// 交给 `LazyVGrid` 的 `.flexible` 去拉伸，Layout 协议没有这条路，只能拿确定的数值 ——
/// 量化就是为了让「拖窗口 / 拖分隔条」不必每帧把这个数值写回 @State。
/// 也因此**不要**在这里拿 `proposal.width` 去「修正」列宽：列宽变 → 卡片高度变 →
/// 内容总高变 → 滚动条出没 → proposal 变，那就是上面那个环的另一条接法。
///
/// ⚠️ Layout 协议不是懒容器：一次排布会实例化全部子视图。
/// 调用方负责控制单次排布的数量级（GalleryGrid 按时间段分组，逐段各排各的，
/// 外层 LazyVStack 保持组级懒加载）。
struct WaterfallLayout: Layout {

    /// 列数（≥1）。
    var columnCount: Int
    /// 每列的固定宽度。
    var columnWidth: CGFloat
    /// 列间距 = 行间距。
    var spacing: CGFloat

    /// 一次贪心排布的结果：每个子视图的偏移 + 尺寸，以及内容总高。
    struct Cache {
        var placement = Placement()
        var signature = Signature.empty
    }

    struct Signature: Equatable {
        let columnCount: Int
        let columnWidth: CGFloat
        let spacing: CGFloat
        let subviewCount: Int

        static let empty = Signature(columnCount: 0, columnWidth: 0, spacing: 0, subviewCount: 0)
    }

    struct Placement {
        var origins: [CGPoint] = []
        var sizes: [CGSize] = []
        var height: CGFloat = 0
    }

    func makeCache(subviews: Subviews) -> Cache {
        Cache(
            placement: computePlacement(subviews: subviews),
            signature: currentSignature(subviewCount: subviews.count)
        )
    }

    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        cache.placement = computePlacement(subviews: subviews)
        cache.signature = currentSignature(subviewCount: subviews.count)
    }

    private func currentSignature(subviewCount: Int) -> Signature {
        Signature(
            columnCount: columnCount,
            columnWidth: columnWidth,
            spacing: spacing,
            subviewCount: subviewCount
        )
    }

    private func ensureCurrent(_ cache: inout Cache, subviews: Subviews) {
        let signature = currentSignature(subviewCount: subviews.count)
        guard cache.signature != signature else { return }
        cache.placement = computePlacement(subviews: subviews)
        cache.signature = signature
    }

    /// 贪心算法本体：按子视图顺序放入当前最矮的列（并列取最左），
    /// 高度用子视图在固定列宽下的自适应高度（ShotCard 的缩略图高度已按图片长宽比
    /// 算好传入，这里量到的是「缩略图 + 图下方两行文字」的整个单元格高度 ——
    /// 卡面在 2026-07 的改版里取消了，量的不再是一块卡片的高度，但对布局没有区别：
    /// 要的一直只是「这个子视图在这个列宽下有多高」）。
    private func computePlacement(subviews: Subviews) -> Placement {
        let columns = max(1, columnCount)
        var columnHeights = [CGFloat](repeating: 0, count: columns)
        var placement = Placement()
        placement.origins.reserveCapacity(subviews.count)
        placement.sizes.reserveCapacity(subviews.count)

        for subview in subviews {
            let size = subview.sizeThatFits(
                ProposedViewSize(width: columnWidth, height: nil)
            )
            // 最矮列，等高时取最左 —— 摆放顺序稳定，同一批数据永远同一形状。
            let column = columnHeights.indices.min {
                columnHeights[$0] < columnHeights[$1]
            } ?? 0
            let x = CGFloat(column) * (columnWidth + spacing)
            placement.origins.append(CGPoint(x: x, y: columnHeights[column]))
            placement.sizes.append(CGSize(width: columnWidth, height: size.height))
            columnHeights[column] += size.height + spacing
        }

        // 每列末尾多加了一个 spacing，总高去掉它。
        placement.height = max(0, (columnHeights.max() ?? spacing) - spacing)
        return placement
    }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache
    ) -> CGSize {
        ensureCurrent(&cache, subviews: subviews)
        let columns = max(1, columnCount)
        let naturalWidth = CGFloat(columns) * columnWidth
            + CGFloat(columns - 1) * spacing
        return CGSize(
            // 撑满提案宽度（列数不吃满时右侧留白，和网格模式的 .leading 对齐一致）。
            width: max(proposal.width ?? naturalWidth, naturalWidth),
            height: cache.placement.height
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache
    ) {
        ensureCurrent(&cache, subviews: subviews)
        let placement = cache.placement
        for (index, subview) in subviews.enumerated() {
            let origin = placement.origins[index]
            subview.place(
                at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y),
                proposal: ProposedViewSize(placement.sizes[index])
            )
        }
    }
}
