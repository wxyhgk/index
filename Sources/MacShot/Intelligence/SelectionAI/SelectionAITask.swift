import Foundation

/// 用户框选局部像素后要执行的智能任务。
///
/// `Kind` 是 Provider 声明能力时使用的稳定标识；带参数的任务仍由 `SelectionAITask`
/// 表达，避免把目标语言之类的运行期输入塞进全局设置。
enum SelectionAITaskKind: String, CaseIterable, Hashable, Sendable {
    case explain
    case translate
    case formulaToLaTeX
    case extractTable
}

enum SelectionAITask: Hashable, Sendable {
    case explain
    case translate(targetLanguage: String)
    case formulaToLaTeX
    case extractTable

    var kind: SelectionAITaskKind {
        switch self {
        case .explain: .explain
        case .translate: .translate
        case .formulaToLaTeX: .formulaToLaTeX
        case .extractTable: .extractTable
        }
    }
}
