import Foundation

enum SelectionAIError: Error, Equatable, Sendable {
    case busy
    case providerUnavailable(providerID: String)
    case unsupportedTask(SelectionAITaskKind)
    case responseKindMismatch(expected: SelectionAITaskKind, actual: SelectionAITaskKind)
}

extension SelectionAIError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .busy:
            "已有一项选区智能任务正在处理"
        case let .providerUnavailable(providerID):
            "选区智能服务“\(providerID)”当前不可用"
        case let .unsupportedTask(kind):
            "当前服务不支持任务“\(kind.rawValue)”"
        case let .responseKindMismatch(expected, actual):
            "智能服务返回了错误的结果类型（需要 \(expected.rawValue)，实际 \(actual.rawValue)）"
        }
    }
}
