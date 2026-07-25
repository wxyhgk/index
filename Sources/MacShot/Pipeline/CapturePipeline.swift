import Foundation

/// 后处理流水线。
///
/// 协调器只调一次 `run(_:)`，不知道有几个处理器、各自做什么、什么时候完成。
/// 处理器之间互不相干，并发执行，任何一个失败或超时都不影响其它的和主流程。
@MainActor
final class CapturePipeline {

    static let shared = CapturePipeline(writer: ShotStoreAttributeWriter())

    private var processors: [CapturePostProcessor] = []
    private let writer: ShotAttributeWriter

    init(writer: ShotAttributeWriter) {
        self.writer = writer
    }

    func register(_ processor: CapturePostProcessor) {
        processors.removeAll { $0.id == processor.id }
        processors.append(processor)
    }

    func run(_ input: PostProcessInput) {
        let writer = self.writer
        for processor in processors where processor.isEnabled {
            Task.detached(priority: .utility) {
                await processor.process(input, writer: writer)
            }
        }
    }
}
