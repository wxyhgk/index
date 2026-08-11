import Foundation

/// ScreenCaptureKit 请求的进程内会话门。
///
/// 超时只能停止客户端等待，不能取消已经交给系统的请求。因此超时后必须保持
/// quarantine，直到那个请求的真实回调到达；否则下一次快捷键会继续向 replayd
/// 叠加请求，把一次系统故障放大成连续崩溃。
final class ScreenCaptureRequestGate: @unchecked Sendable {

    struct SessionToken: Equatable, Sendable {
        fileprivate let id: UUID
    }

    struct OperationToken: Equatable, Sendable {
        fileprivate let sessionID: UUID
        fileprivate let id: UUID
        let name: String
    }

    enum Status: Equatable, Sendable {
        case idle
        case active(operation: String?)
        case quarantined(operation: String)
    }

    enum StartError: Error, Equatable {
        case active(operation: String?)
        case quarantined(operation: String)
    }

    enum Completion: Equatable {
        case completed
        case releasedQuarantine
        case ignored
    }

    private struct PendingOperation {
        let id: UUID
        let name: String
    }

    private enum State {
        case idle
        case active(sessionID: UUID, operation: PendingOperation?)
        case quarantined(sessionID: UUID, operation: PendingOperation)
    }

    private let lock = NSLock()
    private var state: State = .idle

    func beginSession() throws -> SessionToken {
        lock.lock()
        defer { lock.unlock() }

        switch state {
        case .idle:
            let token = SessionToken(id: UUID())
            state = .active(sessionID: token.id, operation: nil)
            return token
        case .active(_, let operation):
            throw StartError.active(operation: operation?.name)
        case .quarantined(_, let operation):
            throw StartError.quarantined(operation: operation.name)
        }
    }

    func beginOperation(in session: SessionToken, name: String) -> OperationToken? {
        lock.lock()
        defer { lock.unlock() }

        guard case .active(let sessionID, nil) = state,
              sessionID == session.id else {
            return nil
        }

        let operation = PendingOperation(id: UUID(), name: name)
        state = .active(sessionID: sessionID, operation: operation)
        return OperationToken(sessionID: sessionID, id: operation.id, name: name)
    }

    /// 返回 true 表示本次调用赢得了超时/回调竞态，调用方应向等待者报告超时。
    @discardableResult
    func timeOut(_ token: OperationToken) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard case .active(let sessionID, let operation?) = state,
              sessionID == token.sessionID,
              operation.id == token.id else {
            return false
        }

        state = .quarantined(sessionID: sessionID, operation: operation)
        return true
    }

    /// 系统回调是解除 quarantine 的唯一正常路径。
    @discardableResult
    func finishOperation(_ token: OperationToken) -> Completion {
        lock.lock()
        defer { lock.unlock() }

        switch state {
        case .active(let sessionID, let operation?)
            where sessionID == token.sessionID && operation.id == token.id:
            state = .active(sessionID: sessionID, operation: nil)
            return .completed
        case .quarantined(let sessionID, let operation)
            where sessionID == token.sessionID && operation.id == token.id:
            state = .idle
            return .releasedQuarantine
        default:
            return .ignored
        }
    }

    /// 成功或普通错误结束会话。若仍有底层请求在飞，不能假装它已结束，而是隔离。
    func finishSession(_ token: SessionToken) {
        lock.lock()
        defer { lock.unlock() }

        switch state {
        case .active(let sessionID, nil) where sessionID == token.id:
            state = .idle
        case .active(let sessionID, let operation?) where sessionID == token.id:
            state = .quarantined(sessionID: sessionID, operation: operation)
        default:
            break
        }
    }

    var status: Status {
        lock.lock()
        defer { lock.unlock() }

        switch state {
        case .idle:
            return .idle
        case .active(_, let operation):
            return .active(operation: operation?.name)
        case .quarantined(_, let operation):
            return .quarantined(operation: operation.name)
        }
    }
}
