import AppKit

/// 选区确认后可以执行的操作。
enum CaptureAction: CaseIterable {
    case pin
    case annotate
    case copy
    case save

    var symbolName: String {
        switch self {
        case .pin: return "pin.fill"
        case .annotate: return "pencil.tip.crop.circle"
        case .copy: return "doc.on.doc"
        case .save: return "square.and.arrow.down"
        }
    }

    var title: String {
        switch self {
        case .pin: return "钉图"
        case .annotate: return "标注"
        case .copy: return "复制"
        case .save: return "保存"
        }
    }
}

struct ToolbarButton {
    /// 视图局部坐标。
    let frame: CGRect
    let action: CaptureAction
}

/// 工具条的布局计算。纯几何，不画东西 —— 视图拿它的结果同时做绘制和命中测试，
/// 两者用同一份数据，不会出现「看到的位置和能点的位置不一致」。
enum ToolbarLayout {

    static let height: CGFloat = 34
    static let gap: CGFloat = 8

    private static let horizontalPadding: CGFloat = 11
    private static let iconSize: CGFloat = 15
    private static let iconGap: CGFloat = 5

    static var labelFont: NSFont { .systemFont(ofSize: 12, weight: .medium) }
    static var iconPointSize: CGFloat { iconSize }
    static var contentInsets: (padding: CGFloat, icon: CGFloat, gap: CGFloat) {
        (horizontalPadding, iconSize, iconGap)
    }

    private static func width(of action: CaptureAction) -> CGFloat {
        let textWidth = (action.title as NSString)
            .size(withAttributes: [.font: labelFont]).width
        return horizontalPadding * 2 + iconSize + iconGap + textWidth
    }

    /// - Parameters:
    ///   - selection: 选区，视图局部坐标
    ///   - bounds: 视图边界
    static func buttons(for selection: CGRect, in bounds: CGRect) -> [ToolbarButton] {
        let widths = CaptureAction.allCases.map(width(of:))
        let barWidth = widths.reduce(0, +)

        // 优先贴在选区下方、右对齐；下面放不下就翻到上方；再放不下就压在选区内侧。
        var barY = selection.minY - gap - height
        if barY < 4 {
            barY = selection.maxY + gap
        }
        if barY + height > bounds.maxY - 4 {
            barY = max(4, selection.minY + gap)
        }
        let barX = min(max(4, selection.maxX - barWidth), bounds.maxX - barWidth - 4)

        var result: [ToolbarButton] = []
        var cursorX = barX
        for (index, action) in CaptureAction.allCases.enumerated() {
            result.append(ToolbarButton(
                frame: CGRect(x: cursorX, y: barY, width: widths[index], height: height),
                action: action
            ))
            cursorX += widths[index]
        }
        return result
    }

    static func barFrame(of buttons: [ToolbarButton]) -> CGRect? {
        guard let first = buttons.first, let last = buttons.last else { return nil }
        return first.frame.union(last.frame)
    }
}
