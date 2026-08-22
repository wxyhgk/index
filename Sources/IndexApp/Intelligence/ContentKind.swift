import CoreGraphics

// MARK: - 内容类型（合成任意软件的方向）
//
// 截图不再只是"一张图"——中间内容区可以渲染任何东西。
// ContentKind 描述"这段内容是什么"，由检测器判定，渲染器消费。
//
// 设计原则：
//   · 纯值类型，可 Equatable / Codable，能存数据库
//   · 不含任何渲染逻辑（那是 UI 层的事）
//   · 新增类型只加 case，不改已有渲染器

/// 截图内容的结构类型。
///
/// 检测优先级（命中即返回，见 `StructuredContentDetector`）：
///   image → text → code → markdown → table → pdf → formula
///
/// 目前只有 `.image` 有完整检测路径（兜底），其余类型
/// 先占位，后续逐个接入检测器。
enum ContentKind: String, Codable, CaseIterable, Sendable {
    /// 纯图片（兜底，当前所有截图的默认类型）。
    case image
    /// 纯文本（OCR 识别出的文字，无结构）。
    case text
    /// 代码片段（有缩进/关键字/语法特征）。
    case code
    /// Markdown 文档（有 #、-、**、` 等标记）。
    case markdown
    /// 表格（OCR 坐标聚类出行列）。
    case table
    /// PDF 页面。
    case pdf
    /// 化学/数学公式。
    case formula

    /// 顶部 bar 的标签文字。
    var label: String {
        switch self {
        case .image: "截图"
        case .text: "文本"
        case .code: "代码"
        case .markdown: "Markdown"
        case .table: "表格"
        case .pdf: "PDF"
        case .formula: "公式"
        }
    }
}
