import AppKit

/// 工具条布局。纯几何 —— 绘制和命中测试用同一份结果，
/// 不会出现「看到的位置和能点的位置不一致」。
///
/// 它不认识任何具体控件：控件从注册表来，宽度和显隐由控件自己回答。
///
/// **尺寸恒定**：至多两行、自然宽度，只由「此刻哪些控件可见」决定，
/// 画布大小 / 窗口缩放一概不参与。此前钉图窗口曾按可用宽度折行，
/// 形成反馈回路 —— 窗口拖窄 → 工具条折行 → 底部条带变高 → 显示倍率变了。
/// 现在工具条是独立的一块（钉图上更是独立的窗口），只有位置随宿主走。
///
/// PixPin 形态：上行 = 工具 + 动作，下行 = 样式（颜色/粗细/字号等，仅当
/// 当前工具声明了对应 `styleAxes` 时出现）。两行各自圆角底板，行距 `interRowGap`。
@MainActor
enum ToolbarLayout {

    static var rowHeight: CGFloat { ToolbarStyle.rowHeight }
    /// 工具条与它依附的矩形之间的固定间距。
    static var gap: CGFloat { ToolbarStyle.anchorGap }
    /// 两行之间的间距（仅当样式行存在时）。
    static var interRowGap: CGFloat { 8 }

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

    // MARK: - 行切分（PixPin 两行）

    /// 样式行判定：仅 `style` 组进下行，其余（tools/history/actions）进上行。
    private static func isStyleRow(_ group: ToolbarGroup) -> Bool { group == .style }

    private static func rowWidth(_ controls: [any ToolbarControl], context: ToolbarContext) -> CGFloat {
        guard !controls.isEmpty else { return 0 }
        var width: CGFloat = 0
        var previous: ToolbarGroup?
        for c in controls {
            if let p = previous, p != c.group { width += ToolbarStyle.separatorWidth }
            width += c.width(context)
            previous = c.group
        }
        return width
    }

    /// 工具条的自然尺寸。**只看内容，不看画布** —— 钉图的工具条窗口据此定尺寸。
    /// 有样式行时为两行高度 + 行距，否则单行。
    static func blockSize(_ context: ToolbarContext) -> CGSize {
        let all = controls(context)
        guard !all.isEmpty else { return .zero }
        let main = all.filter { !isStyleRow($0.group) }
        let style = all.filter { isStyleRow($0.group) }
        let mainWidth = rowWidth(main, context: context)
        let styleWidth = rowWidth(style, context: context)
        let width = max(mainWidth, styleWidth)
        guard width > 0 else { return .zero }
        let hasStyle = !style.isEmpty
        let height = hasStyle ? rowHeight * 2 + interRowGap : rowHeight
        return CGSize(width: width, height: height)
    }

    private static func rowSlots(controls: [any ToolbarControl], at origin: CGPoint, context: ToolbarContext) -> [ToolbarSlot] {
        var slots: [ToolbarSlot] = []
        var x = origin.x
        var previousGroup: ToolbarGroup?
        for control in controls {
            if let previousGroup, previousGroup != control.group {
                slots.append(ToolbarSlot(
                    frame: CGRect(x: x, y: origin.y, width: ToolbarStyle.separatorWidth, height: rowHeight),
                    control: nil
                ))
                x += ToolbarStyle.separatorWidth
            }
            previousGroup = control.group
            let w = control.width(context)
            slots.append(ToolbarSlot(frame: CGRect(x: x, y: origin.y, width: w, height: rowHeight), control: control))
            x += w
        }
        return slots
    }

    // MARK: - 落位

    /// 从给定原点（整块左下角）铺开至多两行。无样式时退化为单行。
    /// 有样式时：上行（main）在 `origin.y + rowHeight + interRowGap`，下行（style）在 `origin.y`。
    static func slots(origin: CGPoint, context: ToolbarContext) -> [ToolbarSlot] {
        let all = controls(context)
        let main = all.filter { !isStyleRow($0.group) }
        let style = all.filter { isStyleRow($0.group) }
        if style.isEmpty {
            return rowSlots(controls: main, at: origin, context: context)
        }
        // 主行在上，样式行在下（贴近选区下方时主行最靠近选区）。
        let mainOrigin = CGPoint(x: origin.x, y: origin.y + rowHeight + interRowGap)
        let styleOrigin = origin
        var slots: [ToolbarSlot] = []
        slots += rowSlots(controls: main, at: mainOrigin, context: context)
        slots += rowSlots(controls: style, at: styleOrigin, context: context)
        return slots
    }

    /// 单行铺开（供钉图等无锚定场景按需调用，复用 `rowSlots`）。
    static func singleRowSlots(origin: CGPoint, context: ToolbarContext) -> [ToolbarSlot] {
        rowSlots(controls: controls(context), at: origin, context: context)
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

        // 两行时主行始终最靠近锚点（PixPin：选区旁永远是工具行）。
        let all = controls(context)
        let hasStyle = all.contains { isStyleRow($0.group) && $0.isVisible(context) }
        if !hasStyle {
            return slots(origin: CGPoint(x: x, y: y), context: context)
        }
        let main = all.filter { !isStyleRow($0.group) }
        let style = all.filter { isStyleRow($0.group) }
        // y < anchor.minY → 贴在选区下方，主行在上；否则贴在上方，主行在下
        let isBelow = y < anchor.minY
        let mainY = isBelow ? y + rowHeight + interRowGap : y
        let styleY = isBelow ? y : y + rowHeight + interRowGap
        var result: [ToolbarSlot] = []
        result += rowSlots(controls: main, at: CGPoint(x: x, y: mainY), context: context)
        result += rowSlots(controls: style, at: CGPoint(x: x, y: styleY), context: context)
        return result
    }

    /// 整块的背景框（单行或两行合并），及按行分组的框。
    static func rowFrame(of slots: [ToolbarSlot]) -> CGRect? {
        slots.map(\.frame).reduce(nil) { (acc: CGRect?, rect) in acc?.union(rect) ?? rect }
    }

    /// 按 y 分行的各行背景框（用于两行各自画圆角底板）。
    static func rowFrames(of slots: [ToolbarSlot]) -> [CGRect] {
        let grouped = Dictionary(grouping: slots, by: { $0.frame.minY })
        return grouped.values.compactMap { rowFrame(of: $0) }.sorted { $0.minY < $1.minY }
    }
}
