import AppKit

enum ToolbarItem: Equatable {
    /// nil 表示指针模式（不画标注）。
    case tool(AnnotationTool?)
    case color(Int)
    case width(Int)
    case undo
    case separator
    case action(ToolbarActionDescriptor)

    var isInteractive: Bool {
        if case .separator = self { return false }
        return true
    }
}

struct ToolbarSlot {
    /// 视图局部坐标。
    let frame: CGRect
    let item: ToolbarItem
}

/// 工具条布局。纯几何，不画东西 —— 绘制和命中测试用同一份结果，
/// 不会出现「看到的位置和能点的位置不一致」。
///
/// 截图覆盖层和钉图窗口共用它，所以两处的工具条是**同一条**，
/// 只有右侧动作组不同。
enum ToolbarLayout {

    enum Alignment {
        /// 贴着锚点右边缘（截图选区）。
        case trailing
        /// 相对锚点居中（钉图窗口）。
        case center
    }

    enum Placement {
        /// 优先锚点下方，放不下翻上方，再放不下压在锚点内侧（截图选区在屏幕上找空位）。
        case adaptive
        /// 固定在锚点下方。调用方保证那里有空间 —— 钉图窗口靠预留底部条带做到这点。
        case below
    }

    struct Configuration {
        /// 工具条依附的矩形，视图局部坐标。
        var anchor: CGRect
        var alignment: Alignment
        var actions: [ToolbarActionDescriptor]
        var tool: AnnotationTool?
        var hasAnnotations: Bool
        var placement: Placement = .adaptive
    }

    static let rowHeight: CGFloat = 34
    static let rowGap: CGFloat = 4
    static let gap: CGFloat = 8

    static let horizontalPadding: CGFloat = 11
    static let iconSize: CGFloat = 15
    static let iconGap: CGFloat = 5

    static var labelFont: NSFont { .systemFont(ofSize: 12, weight: .medium) }

    /// 常驻工具条的工具。椭圆和高亮只保留快捷键（O / H）——
    /// 截图标注里「指出、框住、写字、打码」是绝对主力。
    static let barTools: [AnnotationTool] = [.rect, .arrow, .text, .pixelate]

    /// 比这更小的画布，工具条会盖住内容本身，索性不显示。
    static let minimumCanvasSize = CGSize(width: 120, height: 60)

    private static let toolWidth: CGFloat = 30
    private static let colorWidth: CGFloat = 22
    private static let widthStepWidth: CGFloat = 24
    private static let separatorWidth: CGFloat = 9

    static func width(of item: ToolbarItem) -> CGFloat {
        switch item {
        case .tool, .undo: return toolWidth
        case .color: return colorWidth
        case .width: return widthStepWidth
        case .separator: return separatorWidth
        case .action(let descriptor):
            let text = (descriptor.title as NSString)
                .size(withAttributes: [.font: labelFont]).width
            return horizontalPadding * 2 + iconSize + iconGap + text
        }
    }

    /// 颜色、粗细只在真正拿着画笔时出现；撤销只在有东西可撤时出现。
    private static func editingItems(_ config: Configuration) -> [ToolbarItem] {
        var tools = barTools
        // 用快捷键激活了不在常驻列表里的工具，临时把它显示出来，
        // 否则会出现「按了 H 但工具条上看不出选中了什么」。
        if let tool = config.tool, !tools.contains(tool) {
            tools.append(tool)
        }

        var items: [ToolbarItem] = [.tool(nil)]
        items += tools.map { ToolbarItem.tool($0) }

        if config.tool != nil {
            items.append(.separator)
            items += AnnotationState.palette.indices.map { ToolbarItem.color($0) }
            items.append(.separator)
            items += AnnotationState.widths.indices.map { ToolbarItem.width($0) }
        }

        if config.hasAnnotations {
            items.append(.separator)
            items.append(.undo)
        }
        return items
    }

    /// 单行放得下就单行；放不下就折成「工具行 / 动作行」两行。
    private static func rows(in width: CGFloat, config: Configuration) -> [[ToolbarItem]] {
        let editing = editingItems(config)
        let actions = config.actions.map { ToolbarItem.action($0) }

        let editingWidth = editing.reduce(0) { $0 + self.width(of: $1) }
        let actionsWidth = actions.reduce(0) { $0 + self.width(of: $1) }

        return editingWidth + separatorWidth + actionsWidth <= width - 8
            ? [editing + [.separator] + actions]
            : [editing, actions]
    }

    /// 工具条整体高度。钉图窗口靠它算出底部要预留多少空间。
    static func blockHeight(in width: CGFloat, config: Configuration) -> CGFloat {
        let count = rows(in: width, config: config).count
        return CGFloat(count) * rowHeight + CGFloat(count - 1) * rowGap
    }

    static func slots(in bounds: CGRect, config: Configuration) -> [ToolbarSlot] {
        guard bounds.width >= minimumCanvasSize.width,
              bounds.height >= minimumCanvasSize.height else { return [] }

        let rows = rows(in: bounds.width, config: config)
        let blockWidth = rows.map { row in row.reduce(0) { $0 + width(of: $1) } }.max() ?? 0
        let blockHeight = CGFloat(rows.count) * rowHeight + CGFloat(rows.count - 1) * rowGap

        let anchor = config.anchor
        var blockY = anchor.minY - gap - blockHeight

        if config.placement == .adaptive {
            // 屏幕上找空位：下方放不下就翻上方，再放不下就压在锚点内侧。
            if blockY < 4 {
                blockY = anchor.maxY + gap
            }
            if blockY + blockHeight > bounds.maxY - 4 {
                blockY = max(4, anchor.minY + gap)
            }
        }

        let rawX: CGFloat
        switch config.alignment {
        case .trailing: rawX = anchor.maxX - blockWidth
        case .center:   rawX = anchor.midX - blockWidth / 2
        }
        let blockX = min(max(4, rawX), max(4, bounds.maxX - blockWidth - 4))

        var slots: [ToolbarSlot] = []
        for (rowIndex, row) in rows.enumerated() {
            // 行从上往下排（AppKit 里 Y 向上，所以第一行的 Y 更大）。
            let y = blockY + CGFloat(rows.count - 1 - rowIndex) * (rowHeight + rowGap)
            let rowWidth = row.reduce(0) { $0 + width(of: $1) }
            var x = blockX + (blockWidth - rowWidth)   // 行内右对齐
            for item in row {
                let w = width(of: item)
                slots.append(ToolbarSlot(
                    frame: CGRect(x: x, y: y, width: w, height: rowHeight),
                    item: item
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
