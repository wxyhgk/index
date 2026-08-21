import Foundation

enum SelectionAIExecutionState: Equatable, Sendable {
    case idle
    case running(requestID: UUID, task: SelectionAITaskKind)
}

/// 每个选区智能宿主持有一份执行器。
///
/// 它执行严格单飞：第二个请求不会自动覆盖第一个，也不会因 UI 超时而立即扇出下一项。
/// 用户取消会向 Provider 的 Task 传播；底层真正收尾前状态仍保持 running。
actor SelectionAIExecutor {
    private struct InFlight {
        let requestID: UUID
        let kind: SelectionAITaskKind
        let task: Task<SelectionAIResult, Error>
    }

    private let provider: any SelectionAIProvider
    private var inFlight: InFlight?

    init(provider: any SelectionAIProvider = UnavailableSelectionAIProvider()) {
        self.provider = provider
    }

    var state: SelectionAIExecutionState {
        guard let inFlight else { return .idle }
        return .running(requestID: inFlight.requestID, task: inFlight.kind)
    }

    func execute(_ request: SelectionAIRequest) async throws -> SelectionAIResponse {
        guard inFlight == nil else { throw SelectionAIError.busy }
        guard provider.isAvailable else {
            throw SelectionAIError.providerUnavailable(providerID: provider.id)
        }
        guard provider.supportedTasks.contains(request.task.kind) else {
            throw SelectionAIError.unsupportedTask(request.task.kind)
        }

        let provider = self.provider
        let expectedKind = request.task.kind
        let task = Task<SelectionAIResult, Error> {
            try Task.checkCancellation()
            let result = try await provider.perform(request)
            try Task.checkCancellation()
            guard result.kind == expectedKind else {
                throw SelectionAIError.responseKindMismatch(
                    expected: expectedKind,
                    actual: result.kind
                )
            }
            return result
        }
        inFlight = InFlight(
            requestID: request.id,
            kind: request.task.kind,
            task: task
        )

        do {
            let result = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            finish(requestID: request.id)
            return SelectionAIResponse(
                requestID: request.id,
                task: request.task,
                providerID: provider.id,
                result: result
            )
        } catch {
            finish(requestID: request.id)
            throw error
        }
    }

    func cancelCurrent() {
        inFlight?.task.cancel()
    }

    private func finish(requestID: UUID) {
        guard inFlight?.requestID == requestID else { return }
        inFlight = nil
    }
}
