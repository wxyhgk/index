import AppKit

/// 选区确认后可以执行的操作。
enum CaptureAction: CaseIterable {
    case pin
    case copy
    case save

    var symbolName: String {
        switch self {
        case .pin: return "pin.fill"
        case .copy: return "doc.on.doc"
        case .save: return "square.and.arrow.down"
        }
    }

    var title: String {
        switch self {
        case .pin: return "钉图"
        case .copy: return "复制"
        case .save: return "保存"
        }
    }
}

enum ToolbarItem: Equatable {
    /// nil 表示指针模式（调整选区）。
    case tool(AnnotationTool?)
    case color(Int)
    case width(Int)
    case undo
    case separator
    case action(CaptureAction)

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
enum ToolbarLayout {

    static let rowHeight: CGFloat = 34
    static let rowGap: CGFloat = 4
    static let gap: CGFloat = 8

    static let horizontalPadding: CGFloat = 11
    static let iconSize: CGFloat = 15
    static let iconGap: CGFloat = 5

    static var labelFont: NSFont { .systemFont(ofSize: 12, weight: .medium) }

    private static let toolWidth: CGFloat = 30
    private static let colorWidth: CGFloat = 22
    private static let widthStepWidth: CGFloat = 24
    private static let separatorWidth: CGFloat = 9

    static func width(of item: ToolbarItem) -> CGFloat {
        switch item {
        case .tool: return toolWidth
        case .color: return colorWidth
        case .width: return widthStepWidth
        case .undo: return toolWidth
        case .separator: return separatorWidth
        case .action(let action):
            let text = (action.title as NSString)
                .size(withAttributes: [.font: labelFont]).width
            return horizontalPadding * 2 + iconSize + iconGap + text
        }
    }

    private static var editingItems: [ToolbarItem] {
        var items: [ToolbarItem] = [.tool(nil)]
        items += AnnotationTool.allCases.map { ToolbarItem.tool($0) }
        items.append(.separator)
        items += AnnotationState.palette.indices.map { ToolbarItem.color($0) }
        items.append(.separator)
        items += AnnotationState.widths.indices.map { ToolbarItem.width($0) }
        items.append(.separator)
        items.append(.undo)
        return items
    }

    private static var actionItems: [ToolbarItem] {
        CaptureAction.allCases.map { ToolbarItem.action($0) }
    }

    /// - Parameters:
    ///   - selection: 选区，视图局部坐标
    ///   - bounds: 视图边界
    static func slots(for selection: CGRect, in bounds: CGRect) -> [ToolbarSlot] {
        let editing = editingItems
        let actions = actionItems

        let editingWidth = editing.reduce(0) { $0 + width(of: $1) }
        let actionsWidth = actions.reduce(0) { $0 + width(of: $1) }
        let available = bounds.width - 8

        // 单行放得下就单行；放不下就折成「工具行 / 动作行」两行。
        let singleRow = editingWidth + separatorWidth + actionsWidth <= available
        let rows: [[ToolbarItem]] = singleRow
            ? [editing + [.separator] + actions]
            : [editing, actions]

        let blockWidth = rows.map { row in row.reduce(0) { $0 + width(of: $1) } }.max() ?? 0
        let blockHeight = CGFloat(rows.count) * rowHeight + CGFloat(rows.count - 1) * rowGap

        // 优先贴在选区下方、右对齐；下面放不下就翻到上方；再放不下就压在选区内侧。
        var blockY = selection.minY - gap - blockHeight
        if blockY < 4 {
            blockY = selection.maxY + gap
        }
        if blockY + blockHeight > bounds.maxY - 4 {
            blockY = max(4, selection.minY + gap)
        }
        let blockX = min(max(4, selection.maxX - blockWidth), max(4, bounds.maxX - blockWidth - 4))

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
        let grouped = Dictionary(grouping: slots) { $0.frame.minY }
        return grouped.values.compactMap { row in
            row.map(\.frame).reduce(nil) { (acc: CGRect?, r) in acc?.union(r) ?? r }
        }
    }
}
