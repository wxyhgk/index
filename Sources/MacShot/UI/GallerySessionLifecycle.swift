import Combine
import Foundation

/// 图库窗口一次“打开 -> 关闭”期间的异步工作边界。
///
/// SwiftUI 的 `.task` 会随视图消失自动取消；但 `onReceive` 和 `onAppear`
/// 里手写的 `Task {}` 不属于视图结构，窗口关掉后仍可能继续回填旧元数据或翻页。
/// 这里给这些工作稳定命名，并在会话结束时统一取消。
@MainActor
final class GallerySessionLifecycle: ObservableObject {

    static let shared = GallerySessionLifecycle()

    enum TaskKey: Hashable {
        case initialReload
        case gridSnapshot
        case nextPage
    }

    @Published private(set) var isActive = false
    @Published private(set) var generation = 0

    private struct Entry {
        let token: UUID
        let task: Task<Void, Never>
    }

    private var tasks: [TaskKey: Entry] = [:]

    /// 仅在真正从关闭态进入打开态时建立新会话。窗口已打开时重复 `show()`
    /// 仍属于同一会话，调用方只需替换对应的 reload task。
    @discardableResult
    func begin() -> Int {
        guard !isActive else { return generation }
        cancelAllTasks()
        generation &+= 1
        isActive = true
        return generation
    }

    /// 结束当前会话并取消所有非结构化任务。expectedGeneration 防止一次迟到的
    /// close 把刚重新打开的新会话关掉。
    @discardableResult
    func end(expectedGeneration: Int? = nil) -> Bool {
        if let expectedGeneration, expectedGeneration != generation { return false }
        guard isActive else { return false }
        isActive = false
        cancelAllTasks()
        return true
    }

    /// 同名工作以最新一次为准。库存变化后的元数据快照属于这一类。
    func runReplacing(
        _ key: TaskKey,
        operation: @escaping @MainActor () async -> Void
    ) {
        guard isActive else { return }
        tasks[key]?.task.cancel()
        install(key, operation: operation)
    }

    /// 同名工作单飞。滚动触发器可能让一屏内十几张卡同时 onAppear，分页只能有一份。
    func runIfAbsent(
        _ key: TaskKey,
        operation: @escaping @MainActor () async -> Void
    ) {
        guard isActive, tasks[key] == nil else { return }
        install(key, operation: operation)
    }

    /// 关闭窗口的固定顺序：先退出当前视图（编辑器由 onDisappear 立即落库），
    /// 同步结束会话并取消任务，再让出一次主线程，最后暂停/释放缩略图。
    /// 返回的 task 由窗口控制器持有，重新打开时可取消；generation 守卫则挡住迟到释放。
    func closeAfterExitingView(
        exitView: () -> Void,
        releaseThumbnails: @escaping @MainActor () -> Void
    ) -> Task<Void, Never> {
        let closingGeneration = generation
        exitView()
        _ = end(expectedGeneration: closingGeneration)

        return Task { [weak self] in
            await Task.yield()
            guard !Task.isCancelled,
                  let self,
                  !self.isActive,
                  self.generation == closingGeneration
            else { return }
            releaseThumbnails()
        }
    }

    var activeTaskCount: Int { tasks.count }

    private func install(
        _ key: TaskKey,
        operation: @escaping @MainActor () async -> Void
    ) {
        let token = UUID()
        let task = Task { [weak self] in
            guard !Task.isCancelled else {
                self?.finish(key, token: token)
                return
            }
            await operation()
            self?.finish(key, token: token)
        }
        tasks[key] = Entry(token: token, task: task)
    }

    private func finish(_ key: TaskKey, token: UUID) {
        guard tasks[key]?.token == token else { return }
        tasks.removeValue(forKey: key)
    }

    private func cancelAllTasks() {
        let pending = tasks.values
        tasks.removeAll(keepingCapacity: true)
        for entry in pending { entry.task.cancel() }
    }
}
