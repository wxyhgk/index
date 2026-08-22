import Foundation

enum OverlaySelectionAIExecutionStatus: Equatable {
    case idle
    case running(SelectionAITaskKind)
    case failed(String)
    case completed(SelectionAIResponse)
}

/// Capture 宿主的一次性执行状态。领域层的严格单飞仍由 SelectionAIExecutor 保证；
/// 这里仅保存 UI 可观察状态并隔离取消后的迟到结果。
@MainActor
final class OverlaySelectionAIExecution {
    private let executor: SelectionAIExecutor
    private var requestTask: Task<Void, Never>?
    private var activeRequestID: UUID?

    private(set) var status: OverlaySelectionAIExecutionStatus = .idle
    var onChange: (() -> Void)?

    init() {
        executor = SelectionAIExecutor()
    }

    init(executor: SelectionAIExecutor) {
        self.executor = executor
    }

    var isRunning: Bool {
        if case .running = status { return true }
        return false
    }

    func submit(task: SelectionAITask, input: SelectionAIInput) {
        guard requestTask == nil else { return }
        let request = SelectionAIRequest(task: task, input: input)
        activeRequestID = request.id
        status = .running(task.kind)
        onChange?()

        requestTask = Task { [weak self, executor] in
            do {
                let response = try await executor.execute(request)
                guard let self, self.activeRequestID == request.id else { return }
                self.status = .completed(response)
                self.requestTask = nil
                self.activeRequestID = nil
                self.onChange?()
            } catch is CancellationError {
                guard let self, self.activeRequestID == request.id else { return }
                self.status = .idle
                self.requestTask = nil
                self.activeRequestID = nil
                self.onChange?()
            } catch {
                guard let self, self.activeRequestID == request.id else { return }
                self.status = .failed(Self.userMessage(for: error))
                self.requestTask = nil
                self.activeRequestID = nil
                self.onChange?()
            }
        }
    }

    func reportFailure(_ message: String) {
        guard requestTask == nil else { return }
        status = .failed(message)
        onChange?()
    }

    func reset() {
        activeRequestID = nil
        requestTask?.cancel()
        requestTask = nil
        status = .idle
        onChange?()
    }

    private static func userMessage(for error: Error) -> String {
        if case let SelectionAIError.providerUnavailable(providerID) = error {
            switch providerID {
            case "unconfigured":
                return "尚未配置 AI 服务"
            case "openai-compatible":
                return "尚未配置 AI API Key，请到“设置 → AI”保存"
            default:
                break
            }
        }
        return error.localizedDescription
    }
}
