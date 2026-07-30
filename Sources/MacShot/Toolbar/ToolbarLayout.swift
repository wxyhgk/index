import AppKit

/// 工具条布局。纯几何 —— 绘制和命中测试用同一份结果，
/// 不会出现「看到的位置和能点的位置不一致」。
///
/// 它不认识任何具体控件：控件从注册表来，宽度和显隐由控件自己回答。
///
/// **尺寸恒定**：永远一行、自然宽度，只由「此刻哪些控件可见」决定，
/// 画布大小 / 窗口缩放一概不参与。此前是按可用宽度折行的，在钉图窗口里
/// 形成了一个反馈回路 —— 窗口拖窄 → 工具条折成两行 → 底部条带变高 →
/// 图片显示区变小 → 显示倍率变了；缩放窗口会连带改变工具条的形状。
/// 现在工具条是独立的一块（钉图上更是独立的窗口），只有位置随宿主走。
@MainActor
enum ToolbarLayout {

    static var rowHeight: CGFloat { ToolbarStyle.rowHeight }
    /// 工具条与它依附的矩形之间的固定间距。
    static var gap: CGFloat { ToolbarStyle.anchorGap }

    // MARK: - 内容

    /// 当前可见的控件，已按分组和组内次序排好。
    private static func controls(_ context: ToolbarContext) -> [any ToolbarControl] {
        ToolbarRegistry.shared
            .controls(for: context.scope)
            .filter { $0.isVisible(context) }
    }

    /// 组与组之间插一条分隔线。
    private static func separatorCount(_ controls: [any ToolbarControl]) -> CGFloat {
        var count: CGFloat = 0
        var previous: ToolbarGroup?
        for control in controls {
            if let previous, previous != control.group { count += 1 }
            previous = control.group
        }
        return count
    }

    /// 工具条的自然尺寸。**只看内容，不看画布** —— 钉图的工具条窗口据此定尺寸。
    static func blockSize(_ context: ToolbarContext) -> CGSize {
        let controls = controls(context)
        guard !controls.isEmpty else { return .zero }
        let width = controls.reduce(0) { $0 + $1.width(context) }
            + separatorCount(controls) * ToolbarStyle.separatorWidth
        return CGSize(width: width, height: rowHeight)
    }

    // MARK: - 落位

    /// 从给定原点（行的左下角，视图局部坐标）铺开一行。
    /// 独立工具条窗口直接用它 —— 那里没有「放不放得下」的问题，窗口就是按内容开的。
    static func slots(origin: CGPoint, context: ToolbarContext) -> [ToolbarSlot] {
        var slots: [ToolbarSlot] = []
        var x = origin.x
        var previousGroup: ToolbarGroup?

        for control in controls(context) {
            if let previousGroup, previousGroup != control.group {
                slots.append(ToolbarSlot(
                    frame: CGRect(
                        x: x, y: origin.y,
                        width: ToolbarStyle.separatorWidth, height: rowHeight
                    ),
                    control: nil
                ))
                x += ToolbarStyle.separatorWidth
            }
            previousGroup = control.group

            let width = control.width(context)
            slots.append(ToolbarSlot(
                frame: CGRect(x: x, y: origin.y, width: width, height: rowHeight),
                control: control
            ))
            x += width
        }
        return slots
    }

    /// 贴在锚点下方、相对锚点居中 —— 「内容 / 工具条」上下两块。
    ///
    /// 下方放不下就翻到上方，再放不下就压在锚点内侧：这是屏幕边缘的物理约束，
    /// **只换位置，尺寸和内容一个字节都不变**。
    static func slots(in bounds: CGRect, anchor: CGRect, context: ToolbarContext) -> [ToolbarSlot] {
        let size = blockSize(context)
        guard size.width > 0 else { return [] }

        var y = anchor.minY - gap - size.height
        if y < bounds.minY + 4 { y = anchor.maxY + gap }
        if y + size.height > bounds.maxY - 4 { y = max(bounds.minY + 4, anchor.minY + gap) }

        let leftLimit = bounds.minX + 4
        let rightLimit = max(leftLimit, bounds.maxX - size.width - 4)
        let x = min(max(leftLimit, anchor.midX - size.width / 2), rightLimit)

        return slots(origin: CGPoint(x: x, y: y), context: context)
    }

    /// 整条的背景框，用来画圆角底板。
    static func rowFrame(of slots: [ToolbarSlot]) -> CGRect? {
        slots.map(\.frame).reduce(nil) { (acc: CGRect?, rect) in acc?.union(rect) ?? rect }
    }
}
