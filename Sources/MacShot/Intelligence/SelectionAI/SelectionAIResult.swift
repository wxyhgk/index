import Foundation

struct SelectionAITranslation: Equatable, Sendable {
    let text: String
    let sourceLanguage: String?
    let targetLanguage: String
}

struct SelectionAIFormula: Equatable, Sendable {
    /// 可直接复制的 LaTeX 源码；渲染预览属于 UI 层，不在 Provider 内生成位图。
    let latex: String
}

struct SelectionAITable: Equatable, Sendable {
    /// Markdown 适合预览与粘贴到笔记，CSV 适合进入表格软件。
    let markdown: String
    let csv: String
}

/// Provider 的结构化输出。UI 根据 case 决定预览与复制方式，不解析一段混合文本猜类型。
enum SelectionAIResult: Equatable, Sendable {
    case explanation(markdown: String)
    case translation(SelectionAITranslation)
    case formula(SelectionAIFormula)
    case table(SelectionAITable)

    var kind: SelectionAITaskKind {
        switch self {
        case .explanation: .explain
        case .translation: .translate
        case .formula: .formulaToLaTeX
        case .table: .extractTable
        }
    }
}

/// 一次完成结果携带足够的来源信息，后续保存到图片备注/附件时可追溯，但不把这些
/// 元数据交给 Provider。
struct SelectionAIResponse: Equatable, Sendable {
    let requestID: UUID
    let task: SelectionAITask
    let providerID: String
    let result: SelectionAIResult
}
