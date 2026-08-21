import Foundation

/// 结构化 AI 结果可导出的稳定格式。宿主可以把它们显示成按钮、菜单或快捷键，
/// 不需要重新 switch Provider 的原始结果。
enum SelectionAIExportFormat: String, CaseIterable, Hashable, Sendable {
    case markdown
    case plainText
    case latex
    case csv
}

struct SelectionAIResultExport: Equatable, Sendable {
    let format: SelectionAIExportFormat
    let text: String
}

/// Provider 结果到展示层之间的无 UI 中间形态。`preview` 只用于阅读；复制必须从
/// `exports` 取完整原文，不能复制被面板截断后的预览。
struct SelectionAIResultDocument: Equatable, Sendable {
    let kind: SelectionAITaskKind
    let preview: String
    let exports: [SelectionAIResultExport]
}

extension SelectionAIResponse {
    var document: SelectionAIResultDocument {
        switch result {
        case let .explanation(markdown):
            SelectionAIResultDocument(
                kind: .explain,
                preview: markdown,
                exports: [.init(format: .markdown, text: markdown)]
            )
        case let .translation(translation):
            SelectionAIResultDocument(
                kind: .translate,
                preview: translation.text,
                exports: [.init(format: .plainText, text: translation.text)]
            )
        case let .formula(formula):
            SelectionAIResultDocument(
                kind: .formulaToLaTeX,
                preview: formula.latex,
                exports: [.init(format: .latex, text: formula.latex)]
            )
        case let .table(table):
            SelectionAIResultDocument(
                kind: .extractTable,
                preview: table.markdown,
                exports: [
                    .init(format: .markdown, text: table.markdown),
                    .init(format: .csv, text: table.csv)
                ]
            )
        }
    }
}
