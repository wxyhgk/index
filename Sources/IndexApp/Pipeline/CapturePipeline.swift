import Foundation

/// 后处理流水线。
///
/// 协调器只调一次 `run(_:)`，不知道有几个处理器、各自做什么、什么时候完成。
/// 每张截图是一份有句柄的有界会话；会话内处理器互不相干，并发执行，任何一个
/// 失败或迟到都不影响其它处理器和主流程。
@MainActor
final class CapturePipeline {

    static let shared = CapturePipeline(writer: ShotStoreAttributeWriter())

    private var processors: [CapturePostProcessor] = []
    private let scheduler: BoundedPostProcessScheduler

    init(
        writer: ShotAttributeWriter,
        maxConcurrentSessions: Int = 1
    ) {
        self.scheduler = BoundedPostProcessScheduler(
            writer: writer,
            maxConcurrentSessions: maxConcurrentSessions
        )
    }

    func register(_ processor: CapturePostProcessor) {
        processors.removeAll { $0.id == processor.id }
        processors.append(processor)
    }

    /// 调用方必须先把原图落库。等待队列只保留 URL，不保留 4K `CGImage`；真正拿到
    /// 会话槽位时才在 utility 任务里解码，因此此同步入口不会在主 actor 上编码像素。
    func run(shotID: Int64, originalURL: URL, appBundleID: String?, metadata: ShotMetadata) {
        let enabled = processors.filter(\.isEnabled)
        scheduler.submit(
            shotID: shotID,
            originalURL: originalURL,
            appBundleID: appBundleID,
            metadata: metadata,
            processors: enabled
        )
    }

    func cancelAll() {
        scheduler.cancelAll()
    }

    /// 测试与有序退出使用；普通截图路径不等待派生能力完成。
    func waitUntilIdle() async {
        await scheduler.waitUntilIdle()
    }

    var lifecycleSnapshot: BoundedPostProcessScheduler.Snapshot {
        scheduler.snapshot
    }
}
