import AppKit

/// 工具条布局。纯几何 —— 绘制和命中测试用同一份结果，
/// 不会出现「看到的位置和能点的位置不一致」。
///
/// 它不认识任何具体控件：控件从注册表来，宽度和显隐由控件自己回答。
///
/// **高度恒定**：至多两行，不因画布大小 / 窗口缩放而折行。自然宽度超过
/// 屏幕可用宽度时，只把出口动作的文字收成图标。此前钉图窗口曾按宽度折行，
/// 形成反馈回路 —— 窗口拖窄 → 工具条折行 → 底部条带变高 → 显示倍率变了。
/// 现在工具条是独立的一块（钉图上更是独立的窗口），只有位置随宿主走。
///
/// 两栏形态：第一栏 = 入口（标注/放大/AI选区）+ 动作（复制/保存/录屏/GIF/更多）；
/// 第二栏 = 标注子工具 + 样式 + 历史（仅标注模式激活时出现）。
/// 两行各自圆角底板，行距 `interRowGap`。
@MainActor
enum ToolbarLayout {

    static var rowHeight: CGFloat { ToolbarStyle.rowHeight }
    /// 工具条与它依附的矩形之间的固定间距。
    static var gap: CGFloat { ToolbarStyle.anchorGap }
    /// 两行之间的间距（仅当第二栏存在时）。
    static var interRowGap: CGFloat { 8 }

    // MARK: - 内容

    /// 当前可见的控件，已按分组和组内次序排好。
    private static func controls(
        _ context: ToolbarContext,
        maximumWidth: CGFloat? = nil
    ) -> [any ToolbarControl] {
        let natural = ToolbarRegistry.shared
            .controls(for: context.scope)
            .filter { $0.isVisible(context) }
        guard let maximumWidth else { return natural }
        let main = natural.filter { !isDetailRow($0.group) }
        let detail = natural.filter { isDetailRow($0.group) }

        // 第二栏超宽时收起（标注子工具仍可通过快捷键激活）
        let detailFits = rowWidth(detail, context: context) <= maximumWidth
        let candidates = detailFits ? natural : main
        guard rowWidth(main, context: context) > maximumWidth else { return candidates }

        // 窄屏先只收紧出口动作的文字，工具、历史和动作本身一个都不丢；
        // 完整名称仍由 tooltip 和键盘焦点提示提供。
        return candidates.map { control in
            guard let action = control as? ActionControl else { return control }
            return ActionControl(
                descriptor: action.descriptor,
                order: action.order,
                scope: action.scope,
                showsTitle: false
            )
        }
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

    // MARK: - 行切分（PixPin 两行：上行工具+操作，下行颜色+线宽+字号）

    /// 第二栏判定：`.annotation` + `.style` + `.history` 进第二行，
    /// 其余（`.entry` + `.actions`）进第一行。
    private static func isDetailRow(_ group: ToolbarGroup) -> Bool {
        group == .annotation || group == .style || group == .history
    }

    private static func controlWidth(
        _ control: any ToolbarControl,
        context: ToolbarContext,
        compactMain: Bool
    ) -> CGFloat {
        let natural = control.width(context)
        guard compactMain, !isDetailRow(control.group) else { return natural }
        return min(natural, ToolbarStyle.compactIconButtonWidth)
    }

    private static func separatorWidth(compactMain: Bool) -> CGFloat {
        compactMain ? ToolbarStyle.compactSeparatorWidth : ToolbarStyle.separatorWidth
    }

    private static func rowWidth(
        _ controls: [any ToolbarControl],
        context: ToolbarContext,
        compactMain: Bool = false
    ) -> CGFloat {
        guard !controls.isEmpty else { return 0 }
        var width: CGFloat = 0
        var previous: ToolbarGroup?
        for c in controls {
            if let p = previous, p != c.group {
                width += separatorWidth(compactMain: compactMain)
            }
            width += controlWidth(c, context: context, compactMain: compactMain)
            previous = c.group
        }
        return width
    }

    private static func usesCompactMainSpacing(
        _ main: [any ToolbarControl],
        context: ToolbarContext,
        maximumWidth: CGFloat?
    ) -> Bool {
        guard let maximumWidth else { return false }
        return rowWidth(main, context: context) > maximumWidth
    }

    /// 工具条尺寸。默认取自然宽；给出屏幕上限时可收起动作文字。
    /// 有第二栏时为两行高度 + 行距，否则单行。
    static func blockSize(_ context: ToolbarContext, maximumWidth: CGFloat? = nil) -> CGSize {
        let all = controls(context, maximumWidth: maximumWidth)
        guard !all.isEmpty else { return .zero }
        let main = all.filter { !isDetailRow($0.group) }
        let style = all.filter { isDetailRow($0.group) }
        let compactMain = usesCompactMainSpacing(
            main,
            context: context,
            maximumWidth: maximumWidth
        )
        let mainWidth = rowWidth(main, context: context, compactMain: compactMain)
        let styleWidth = rowWidth(style, context: context)
        let width = max(mainWidth, styleWidth)
        guard width > 0 else { return .zero }
        let hasStyle = !style.isEmpty
        let height = hasStyle ? rowHeight * 2 + interRowGap : rowHeight
        return CGSize(width: width, height: height)
    }

    private static func rowSlots(
        controls: [any ToolbarControl],
        at origin: CGPoint,
        context: ToolbarContext,
        compactMain: Bool = false
    ) -> [ToolbarSlot] {
        var slots: [ToolbarSlot] = []
        var x = origin.x
        var previousGroup: ToolbarGroup?
        for control in controls {
            if let previousGroup, previousGroup != control.group {
                slots.append(ToolbarSlot(
                    frame: CGRect(
                        x: x,
                        y: origin.y,
                        width: separatorWidth(compactMain: compactMain),
                        height: rowHeight
                    ),
                    control: nil
                ))
                x += separatorWidth(compactMain: compactMain)
            }
            previousGroup = control.group
            let w = controlWidth(control, context: context, compactMain: compactMain)
            slots.append(ToolbarSlot(frame: CGRect(x: x, y: origin.y, width: w, height: rowHeight), control: control))
            x += w
        }
        return slots
    }

    // MARK: - 落位

    /// 从给定原点（整块左下角）铺开至多两行。无第二栏时退化为单行。
    /// 有第二栏时：上行（main）在 `origin.y + rowHeight + interRowGap`，下行（detail）在 `origin.y`。
    static func slots(
        origin: CGPoint,
        context: ToolbarContext,
        maximumWidth: CGFloat? = nil
    ) -> [ToolbarSlot] {
        let all = controls(context, maximumWidth: maximumWidth)
        let main = all.filter { !isDetailRow($0.group) }
        let style = all.filter { isDetailRow($0.group) }
        let compactMain = usesCompactMainSpacing(
            main,
            context: context,
            maximumWidth: maximumWidth
        )
        if style.isEmpty {
            return rowSlots(
                controls: main,
                at: origin,
                context: context,
                compactMain: compactMain
            )
        }
        // 主行在上，样式行在下（贴近选区下方时主行最靠近选区）。
        let mainOrigin = CGPoint(x: origin.x, y: origin.y + rowHeight + interRowGap)
        let styleOrigin = origin
        var slots: [ToolbarSlot] = []
        slots += rowSlots(
            controls: main,
            at: mainOrigin,
            context: context,
            compactMain: compactMain
        )
        slots += rowSlots(controls: style, at: styleOrigin, context: context)
        return slots
    }

    /// 单行铺开（供钉图等无锚定场景按需调用，复用 `rowSlots`）。
    static func singleRowSlots(origin: CGPoint, context: ToolbarContext) -> [ToolbarSlot] {
        rowSlots(controls: controls(context), at: origin, context: context)
    }

    /// 贴在锚点下方、相对锚点居中 —— 「内容 / 工具条」上下两块。
    ///
    /// **第一栏位置固定**：x 基于第一栏宽度居中，y 选区下方紧贴。
    /// 第二栏在第一栏远离选区的一侧出现/消失，不影响第一栏位置。
    /// 下方放不下就翻到上方，再放不下就压在锚点内侧。
    static func slots(in bounds: CGRect, anchor: CGRect, context: ToolbarContext) -> [ToolbarSlot] {
        let maximumWidth = max(0, bounds.width - 8)
        let all = controls(context, maximumWidth: maximumWidth)
        let main = all.filter { !isDetailRow($0.group) }
        let detail = all.filter { isDetailRow($0.group) }
        guard !main.isEmpty else { return [] }

        let compactMain = usesCompactMainSpacing(main, context: context, maximumWidth: maximumWidth)
        let mainW = rowWidth(main, context: context, compactMain: compactMain)
        guard mainW > 0 else { return [] }

        // 第一栏 x 基于自身宽度居中（不随第二栏变化）
        let leftLimit = bounds.minX + 4
        let rightLimit = max(leftLimit, bounds.maxX - mainW - 4)
        let x = min(max(leftLimit, anchor.midX - mainW / 2), rightLimit)

        // 第一栏 y 固定：选区下方紧贴
        var mainY = anchor.minY - gap - rowHeight
        if mainY < bounds.minY + 4 { mainY = anchor.maxY + gap }
        if mainY + rowHeight > bounds.maxY - 4 { mainY = max(bounds.minY + 4, anchor.minY + gap) }

        var result: [ToolbarSlot] = []
        result += rowSlots(controls: main, at: CGPoint(x: x, y: mainY), context: context, compactMain: compactMain)

        // 第二栏在第一栏远离选区的一侧
        if !detail.isEmpty {
            let detailW = rowWidth(detail, context: context)
            let totalW = max(mainW, detailW)
            let detailX = x + (totalW - detailW) / 2
            let detailY: CGFloat
            if mainY < anchor.minY {
                detailY = mainY - rowHeight - interRowGap
            } else {
                detailY = mainY + rowHeight + interRowGap
            }
            result += rowSlots(controls: detail, at: CGPoint(x: detailX, y: detailY), context: context)
        }

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
