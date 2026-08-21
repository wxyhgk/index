import Foundation

/// 模型/服务的唯一扩展点。
///
/// 本地模型实现可以继续放在 `Intelligence/`；HTTP、鉴权、Keychain 等平台副作用必须
/// 由 `Platform/` 中的实现承担。Provider 应响应 Task 取消；若底层 SDK 无法取消，执行器
/// 会保持 busy 直到该请求真正结束，避免同一宿主继续扇出孤儿请求。
protocol SelectionAIProvider: Sendable {
    var id: String { get }
    var isAvailable: Bool { get }
    var supportedTasks: Set<SelectionAITaskKind> { get }

    func perform(_ request: SelectionAIRequest) async throws -> SelectionAIResult
}

extension SelectionAIProvider {
    var isAvailable: Bool { true }
}
