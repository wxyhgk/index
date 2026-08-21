import CoreGraphics
import Foundation
import ScreenCaptureKit

/// Index 进程内唯一的 ScreenCaptureKit 事务入口。
///
/// 一次事务覆盖内容枚举以及紧随其后的截图或流启动，避免普通截图、录屏和
/// 滚动截图在 replayd 中交错初始化。客户端超时或取消只结束本地等待；已经
/// 交给系统的调用仍保持隔离，直到真实回调抵达后才允许下一次事务。
final class MacScreenCaptureBroker: @unchecked Sendable {

    static let shared = MacScreenCaptureBroker()

    struct Session: Sendable {
        fileprivate let token: ScreenCaptureRequestGate.SessionToken
    }

    private let requestGate: ScreenCaptureRequestGate
    private let timeout: TimeInterval

    init(
        requestGate: ScreenCaptureRequestGate = ScreenCaptureRequestGate(),
        timeout: TimeInterval = 5
    ) {
        self.requestGate = requestGate
        self.timeout = timeout
    }

    func beginSession() throws -> Session {
        do {
            return Session(token: try requestGate.beginSession())
        } catch ScreenCaptureRequestGate.StartError.active(let operation) {
            throw CaptureError.screenCaptureRequestInFlight(operation)
        } catch ScreenCaptureRequestGate.StartError.quarantined(let operation) {
            throw CaptureError.screenCaptureRequestQuarantined(operation)
        }
    }

    func finishSession(_ session: Session) {
        requestGate.finishSession(session.token)
    }

    func shareableContent(
        in session: Session,
        operationName: String = "shareable-content"
    ) async throws -> SCShareableContent {
        try await perform(in: session, operationName: operationName) { completion in
            SCShareableContent.getExcludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            ) { content, error in
                if let content {
                    completion(.success(content))
                } else if let error {
                    completion(.failure(error))
                } else {
                    completion(.failure(CaptureError.screenCaptureUnavailable))
                }
            }
        }
    }

    func captureImage(
        filter: SCContentFilter,
        configuration: SCStreamConfiguration,
        in session: Session,
        operationName: String
    ) async throws -> CGImage {
        try await perform(in: session, operationName: operationName) { completion in
            SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            ) { image, error in
                if let image {
                    completion(.success(image))
                } else if let error {
                    completion(.failure(error))
                } else {
                    completion(.failure(CaptureError.screenCaptureUnavailable))
                }
            }
        }
    }

    func startCapture(
        _ stream: SCStream,
        in session: Session,
        operationName: String
    ) async throws {
        let _: Void = try await perform(
            in: session,
            operationName: operationName
        ) { completion in
            stream.startCapture { error in
                if let error {
                    completion(.failure(error))
                } else {
                    completion(.success(()))
                }
            }
        }
    }

    private func perform<Value>(
        in session: Session,
        operationName: String,
        start: (@escaping (Result<Value, any Error>) -> Void) -> Void
    ) async throws -> Value {
        guard let operation = requestGate.beginOperation(
            in: session.token,
            name: operationName
        ) else {
            throw CaptureError.screenCaptureUnavailable
        }

        let waiter = ScreenCaptureOperationWaiter<Value>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiter.install(continuation)
                start { [requestGate] result in
                    let completion = requestGate.finishOperation(operation)
                    if completion == .releasedQuarantine {
                        NSLog(
                            "[Index] ScreenCaptureKit 迟到回调已结束隔离 stage=%@",
                            operation.name
                        )
                    }
                    waiter.resume(with: result)
                }
                DispatchQueue.global(qos: .userInitiated).asyncAfter(
                    deadline: .now() + timeout
                ) { [requestGate] in
                    guard requestGate.timeOut(operation) else { return }
                    NSLog(
                        "[Index] ScreenCaptureKit 等待超时并进入隔离 stage=%@",
                        operation.name
                    )
                    waiter.resume(
                        with: .failure(CaptureError.screenCaptureTimedOut(operation.name))
                    )
                }
            }
        } onCancel: { [requestGate] in
            guard requestGate.timeOut(operation) else { return }
            NSLog(
                "[Index] ScreenCaptureKit 客户端取消并进入隔离 stage=%@",
                operation.name
            )
            waiter.resume(with: .failure(CancellationError()))
        }
    }
}

/// 处理系统回调、超时和 Task 取消之间的三方竞态，只允许恢复等待者一次。
private final class ScreenCaptureOperationWaiter<Value>: @unchecked Sendable {

    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, any Error>?
    private var pendingResult: Result<Value, any Error>?
    private var isFinished = false

    func install(_ continuation: CheckedContinuation<Value, any Error>) {
        lock.lock()
        if let pendingResult {
            self.pendingResult = nil
            lock.unlock()
            continuation.resume(with: pendingResult)
        } else if isFinished {
            lock.unlock()
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    func resume(with result: Result<Value, any Error>) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        if let continuation {
            self.continuation = nil
            lock.unlock()
            continuation.resume(with: result)
        } else {
            pendingResult = result
            lock.unlock()
        }
    }
}
