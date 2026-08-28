import Foundation

/// 输入联想面板消费的轻量结果。这里只保留展示与定位信息，不泄漏主 App 的 Shot 模型。
public struct IndexSearchResult: Identifiable, Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case screenshot
        case markdown
        case code
        case clipboardText
        case clipboardImage
        case clipboardFile

        public var displayName: String {
            switch self {
            case .screenshot: return "截图"
            case .markdown: return "Markdown"
            case .code: return "代码"
            case .clipboardText: return "剪贴板文字"
            case .clipboardImage: return "剪贴板图片"
            case .clipboardFile: return "剪贴板文件"
            }
        }
    }

    public let id: String
    public let recordID: Int64
    public let kind: Kind
    public let title: String
    public let subtitle: String
    public let snippet: String
    public let assetURL: URL?
    public let capturedAt: Date
    public let score: Int

    public init(
        id: String,
        recordID: Int64,
        kind: Kind,
        title: String,
        subtitle: String,
        snippet: String,
        assetURL: URL?,
        capturedAt: Date,
        score: Int
    ) {
        self.id = id
        self.recordID = recordID
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.snippet = snippet
        self.assetURL = assetURL
        self.capturedAt = capturedAt
        self.score = score
    }
}
