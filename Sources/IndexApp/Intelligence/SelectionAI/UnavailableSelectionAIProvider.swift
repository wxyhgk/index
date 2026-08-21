import Foundation

/// 尚未配置模型时的安全默认值。它不触网、不读取图片，也让上层可以先完成 UI 装配。
struct UnavailableSelectionAIProvider: SelectionAIProvider {
    let id: String
    let isAvailable = false
    let supportedTasks = Set(SelectionAITaskKind.allCases)

    init(id: String = "unconfigured") {
        self.id = id
    }

    func perform(_ request: SelectionAIRequest) async throws -> SelectionAIResult {
        throw SelectionAIError.providerUnavailable(providerID: id)
    }
}
