import SwiftUI

// MARK: - 搜索结果条目（统一模型）
//
// 混合截图和剪贴板历史的统一展示模型。
// 列表、预览、后续 Enter 动作都基于这个类型分派。

struct SearchEntry: Identifiable, Equatable {
    enum Source: Equatable {
        case clipboard(ClipboardHistoryItem)
        case shot(Shot)
    }

    let id: String
    let source: Source
    let title: String
    let subtitle: String
    let timestamp: Date
    let kind: EntryKind

    enum EntryKind: Equatable {
        case screenshot
        case recording
        case clipboardText
        case clipboardImage
        case clipboardFile
    }

    var kindIcon: String {
        switch kind {
        case .screenshot: return "photo"
        case .recording: return "video"
        case .clipboardText: return "textformat"
        case .clipboardImage: return "photo.on.rectangle"
        case .clipboardFile: return "doc"
        }
    }

    var kindColor: Color {
        switch kind {
        case .screenshot: return .blue
        case .recording: return .orange
        case .clipboardText: return .green
        case .clipboardImage: return .purple
        case .clipboardFile: return .gray
        }
    }

    var kindLabel: String {
        switch kind {
        case .screenshot: return "截图"
        case .recording: return "录屏"
        case .clipboardText: return "文本"
        case .clipboardImage: return "图片"
        case .clipboardFile: return "文件"
        }
    }

    static func == (lhs: SearchEntry, rhs: SearchEntry) -> Bool {
        lhs.id == rhs.id
    }
}
