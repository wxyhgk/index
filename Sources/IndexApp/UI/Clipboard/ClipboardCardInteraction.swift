import CoreGraphics
import Foundation

// ============================================================
// MARK: - 剪贴板卡片 hit-test 区域逻辑
//
// NSCollectionView 使用左下角原点。只有中间内容层承担选中与双击，
// 顶部和底部 Bar 留给各自的控件与后续扩展。
// ============================================================

enum ClipboardCardInteractionZone: Equatable {
    case header
    case content
    case footer
    case outside
}

enum ClipboardCardInteractionZones {
    static func zone(at point: NSPoint, in size: NSSize) -> ClipboardCardInteractionZone {
        guard point.x >= 0, point.x < size.width,
              point.y >= 0, point.y < size.height
        else { return .outside }
        if point.y < ClipboardCardMetrics.footerHeight { return .footer }
        if point.y >= size.height - ClipboardCardMetrics.headerHeight { return .header }
        return .content
    }

    static func selectsCard(at point: NSPoint, in size: NSSize) -> Bool {
        zone(at: point, in: size) == .content
    }
}
