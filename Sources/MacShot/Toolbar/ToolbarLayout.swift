import AppKit

/// 工具条布局。纯几何 —— 绘制和命中测试用同一份结果，
/// 不会出现「看到的位置和能点的位置不一致」。
///
/// 它不认识任何具体控件：控件从注册表来，宽度和显隐由控件自己回答。
@MainActor
enum ToolbarLayout {

    enum Alignment {
        /// 贴着锚点右边缘（截图选区）。
        case trailing
        /// 相对锚点居中（钉图窗口）。
        case center
    }

    enum Placement {
        /// 在画布内找空位：下方 → 上方 → 压在锚点内侧。
        case adaptive
        /// 固定在锚点下方，调用方保证那里有空间（钉图靠预留条带做到）。
        case below
    }

    struct Configuration {
        /// 工具条依附的矩形，视图局部坐标。
        var anchor: CGRect
        var alignment: Alignment
        var placement: Placement = .adaptive
        var context: ToolbarContext
    }

    static var rowHeight: CGFloat { ToolbarStyle.rowHeight }
    static var rowGap: CGFloat { ToolbarStyle.rowGap }
    static var gap: CGFloat { ToolbarStyle.anchorGap }

    // MARK: - 分行

    /// 按分组切成若干行：工具/样式/历史一行，动作一行。放得下就并成一行。
    private static func rows(in width: CGFloat, config: Configuration) -> [[any ToolbarControl]] {
        let visible = ToolbarRegistry.shared
            .controls(for: config.context.scope)
            .filter { $0.isVisible(config.context) }

        let editing = visible.filter { $0.group < .actions }
        let actions = visible.filter { $0.group == .actions }

        func span(_ controls: [any ToolbarControl]) -> CGFloat {
            controls.reduce(0) { $0 + $1.width(config.context) }
                + separatorCount(controls) * ToolbarStyle.separatorWidth
        }

        let combined = span(editing) + ToolbarStyle.separatorWidth + span(actions)
        if combined <= width - 8 {
            return [editing + actions]
        }
        return [editing, actions].filter { !$0.isEmpty }
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

    /// 工具条整体高度。钉图窗口靠它算出底部要预留多少空间。
    static func blockHeight(in width: CGFloat, config: Configuration) -> CGFloat {
        let count = rows(in: width, config: config).count
        return CGFloat(count) * rowHeight + CGFloat(max(0, count - 1)) * rowGap
    }

    // MARK: - 落位

    static func slots(in bounds: CGRect, config: Configuration) -> [ToolbarSlot] {
        guard bounds.width >= ToolbarStyle.minimumCanvasSize.width,
              bounds.height >= ToolbarStyle.minimumCanvasSize.height else { return [] }

        let rows = rows(in: bounds.width, config: config)
        guard !rows.isEmpty else { return [] }

        func rowWidth(_ controls: [any ToolbarControl]) -> CGFloat {
            controls.reduce(0) { $0 + $1.width(config.context) }
                + separatorCount(controls) * ToolbarStyle.separatorWidth
        }

        let blockWidth = rows.map(rowWidth).max() ?? 0
        let blockHeight = CGFloat(rows.count) * rowHeight + CGFloat(rows.count - 1) * rowGap
        let anchor = config.anchor

        var blockY = anchor.minY - gap - blockHeight
        if config.placement == .adaptive {
            if blockY < 4 { blockY = anchor.maxY + gap }
            if blockY + blockHeight > bounds.maxY - 4 { blockY = max(4, anchor.minY + gap) }
        }

        let rawX: CGFloat
        switch config.alignment {
        case .trailing: rawX = anchor.maxX - blockWidth
        case .center:   rawX = anchor.midX - blockWidth / 2
        }
        let blockX = min(max(4, rawX), max(4, bounds.maxX - blockWidth - 4))

        var slots: [ToolbarSlot] = []
        for (rowIndex, controls) in rows.enumerated() {
            // 行从上往下排（AppKit 里 Y 向上，所以第一行的 Y 更大）。
            let y = blockY + CGFloat(rows.count - 1 - rowIndex) * (rowHeight + rowGap)
            var x = blockX + (blockWidth - rowWidth(controls))   // 行内右对齐
            var previousGroup: ToolbarGroup?

            for control in controls {
                if let previousGroup, previousGroup != control.group {
                    slots.append(ToolbarSlot(
                        frame: CGRect(x: x, y: y, width: ToolbarStyle.separatorWidth, height: rowHeight),
                        control: nil
                    ))
                    x += ToolbarStyle.separatorWidth
                }
                previousGroup = control.group

                let w = control.width(config.context)
                slots.append(ToolbarSlot(
                    frame: CGRect(x: x, y: y, width: w, height: rowHeight),
                    control: control
                ))
                x += w
            }
        }
        return slots
    }

    /// 每一行的背景框，用来画圆角底板。
    static func rowFrames(of slots: [ToolbarSlot]) -> [CGRect] {
        Dictionary(grouping: slots) { $0.frame.minY }.values.compactMap { row in
            row.map(\.frame).reduce(nil) { (acc: CGRect?, r) in acc?.union(r) ?? r }
        }
    }
}
