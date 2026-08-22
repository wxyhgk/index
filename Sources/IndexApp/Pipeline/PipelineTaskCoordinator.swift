import Foundation

/// 截图后处理的有界会话调度器。
///
/// 一张截图是一份会话：等待队列只保存已经落库的 URL，获得活跃槽位之后才解码
/// `CGImage`；会话内的处理器仍用 structured concurrency 并发运行。这样连续 4K
/// 截图不会在内存里排队，同时一个处理器迟到或取消不会跳过同会话里的其它处理器。
@MainActor
final class BoundedPostProcessScheduler {
    struct Snapshot: Equatable {
        let activeSessions: Int
        let pendingSessions: Int
    }

    private struct WorkItem: @unchecked Sendable {
        let id = UUID()
        let shotID: Int64
        let originalURL: URL
        let appBundleID: String?
        let metadata: ShotMetadata
        let processors: [any CapturePostProcessor]
    }

    private let writer: any ShotAttributeWriter
    private let maxConcurrentSessions: Int
    private var activeTasks: [UUID: Task<Void, Never>] = [:]
    private var pending: [WorkItem] = []
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        writer: any ShotAttributeWriter,
        maxConcurrentSessions: Int
    ) {
        precondition(maxConcurrentSessions > 0)
        self.writer = writer
        self.maxConcurrentSessions = maxConcurrentSessions
    }

    func submit(
        shotID: Int64,
        originalURL: URL,
        appBundleID: String?,
        metadata: ShotMetadata,
        processors: [any CapturePostProcessor]
    ) {
        guard !processors.isEmpty else { return }
        let work = WorkItem(
            shotID: shotID,
            originalURL: originalURL,
            appBundleID: appBundleID,
            metadata: metadata,
            processors: processors
        )

        if activeTasks.count < maxConcurrentSessions {
            start(work)
            return
        }
        pending.append(work)
    }

    func cancelAll() {
        pending.removeAll()
        for task in activeTasks.values {
            task.cancel()
        }
        resumeIdleWaitersIfNeeded()
    }

    func waitUntilIdle() async {
        guard !activeTasks.isEmpty || !pending.isEmpty else { return }
        await withCheckedContinuation { continuation in
            idleWaiters.append(continuation)
        }
    }

    var snapshot: Snapshot {
        Snapshot(
            activeSessions: activeTasks.count,
            pendingSessions: pending.count
        )
    }

    private func start(_ work: WorkItem) {
        let writer = writer
        let task = Task.detached(priority: .utility) {
            guard !Task.isCancelled else {
                await MainActor.run { [weak self] in self?.didFinish(work.id) }
                return
            }
            guard let image = ImageCodec.load(from: work.originalURL) else {
                NSLog("[Index] 后处理无法读取截图 \(work.shotID)：\(work.originalURL.path)")
                await MainActor.run { [weak self] in self?.didFinish(work.id) }
                return
            }
            let input = PostProcessInput(
                shotID: work.shotID,
                image: image,
                appBundleID: work.appBundleID,
                metadata: work.metadata
            )
            await withTaskGroup(of: Void.self) { group in
                for processor in work.processors {
                    group.addTask(priority: .utility) {
                        guard !Task.isCancelled else { return }
                        await processor.process(input, writer: writer)
                    }
                }
                await group.waitForAll()
            }

            await MainActor.run { [weak self] in
                self?.didFinish(work.id)
            }
        }
        activeTasks[work.id] = task
    }

    private func didFinish(_ id: UUID) {
        activeTasks[id] = nil
        while activeTasks.count < maxConcurrentSessions, !pending.isEmpty {
            start(pending.removeFirst())
        }
        resumeIdleWaitersIfNeeded()
    }

    private func resumeIdleWaitersIfNeeded() {
        guard activeTasks.isEmpty, pending.isEmpty else { return }
        let waiters = idleWaiters
        idleWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}

/// 后台回填的单飞门。
///
/// 重复触发不会并发启动第二份全库扫描，而是只保留最新的一次后续重扫；取消是
/// 协作式的，旧任务真正退出之前，新任务仍留在门后，保证任意时刻最多一份回填。
@MainActor
final class SingleFlightTaskCoordinator {
    static let shared = SingleFlightTaskCoordinator()

    typealias Operation = @Sendable () async -> Void

    private var activeTask: Task<Void, Never>?
    private var activeToken: UUID?
    private var pendingOperation: Operation?
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    var isRunning: Bool { activeTask != nil }
    var hasPendingRetrigger: Bool { pendingOperation != nil }

    /// - Returns: `true` 表示立即启动，`false` 表示与当前单飞合并、稍后重扫。
    @discardableResult
    func trigger(_ operation: @escaping Operation) -> Bool {
        guard activeTask == nil else {
            pendingOperation = operation
            return false
        }
        start(operation)
        return true
    }

    func cancel() {
        pendingOperation = nil
        activeTask?.cancel()
    }

    func waitUntilIdle() async {
        guard activeTask != nil || pendingOperation != nil else { return }
        await withCheckedContinuation { continuation in
            idleWaiters.append(continuation)
        }
    }

    private func start(_ operation: @escaping Operation) {
        let token = UUID()
        activeToken = token
        activeTask = Task.detached(priority: .utility) {
            if !Task.isCancelled {
                await operation()
            }
            await MainActor.run { [weak self] in
                self?.didFinish(token: token)
            }
        }
    }

    private func didFinish(token: UUID) {
        guard activeToken == token else { return }
        activeTask = nil
        activeToken = nil
        if let next = pendingOperation {
            pendingOperation = nil
            start(next)
            return
        }

        let waiters = idleWaiters
        idleWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}
