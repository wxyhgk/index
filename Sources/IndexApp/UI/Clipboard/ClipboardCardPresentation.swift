import CoreGraphics
import Foundation

// ============================================================
// MARK: - 剪贴板卡片展示层（纯数据 / 纯逻辑）
//
// 尺寸规格、文案生成、相对时间、缓存键、改名草稿。
// 无 UI、无跨引用。
// ============================================================

/// 剪贴板卡片只有两种固定规格。尺寸集中在这里，主窗口和快捷弹窗
/// 不再各自维护一份字面量，避免布局尺寸与 SwiftUI 内容帧悄悄漂移。
enum ClipboardCardMetrics {
    static let gridWidth: CGFloat = 200
    static let gridHeight: CGFloat = 178
    static let popupWidth: CGFloat = 220
    static let popupHeight: CGFloat = 196
    static let headerHeight: CGFloat = 52
    static let footerHeight: CGFloat = 26
}

/// 编辑中的草稿故意不是 ObservableObject。原生文本框每输入一个字符只更新这个
/// 引用，不让整个 RecyclingCardCollectionView 因父级 @State 改变而刷新可见卡片。
final class ClipboardCardRenameDraft {
    var text = ""
}

enum ClipboardCardPresentation {
    static func typeLabel(for kind: ClipboardHistoryKind) -> String {
        switch kind {
        case .text: return "文本"
        case .image: return "图片"
        case .file: return "文件"
        }
    }

    static func displayTitle(for item: ClipboardHistoryItem) -> String {
        if let customTitle = item.title?.trimmingCharacters(in: .whitespacesAndNewlines),
           !customTitle.isEmpty {
            return customTitle
        }
        return typeLabel(for: item.kind)
    }

    static func metadata(for item: ClipboardHistoryItem) -> String {
        switch item.kind {
        case .text:
            return "\((item.text ?? item.summary ?? "").count.formatted()) 个字符"
        case .image:
            let summary = item.summary ?? "图片"
            return summary.hasPrefix("图片 ") ? String(summary.dropFirst(3)) : summary
        case .file:
            return item.summary ?? "文件"
        }
    }

    static func relativeTime(for date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "今天" }
        if calendar.isDateInYesterday(date) { return "昨天" }

        let start = calendar.startOfDay(for: date)
        let end = calendar.startOfDay(for: now)
        let days = calendar.dateComponents([.day], from: start, to: end).day ?? 0
        if days > 1, days < 7 { return "\(days) 天前" }
        if days >= 7, days < 14 { return "上周" }

        return date.formatted(.dateTime.year().month().day())
    }
}

extension ClipboardHistoryItem {
    var thumbnailCacheKey: String { "clipboard:\(contentHash)" }
    var viewportIdentity: String {
        id.map { "clipboard-item:\($0)" } ?? "clipboard-hash:\(contentHash)"
    }
}
