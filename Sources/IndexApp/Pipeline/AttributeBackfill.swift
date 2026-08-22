import Foundation
import CoreGraphics

/// 历史数据回填：给某项派生能力上线之前的截图补上对应属性
/// （`category` / `vision.labels` / `vision.featureprint`）。
///
/// 启动或能力变为可用时调用 `runIfNeeded()`。全局单飞、utility 优先级、按小批次
/// 串行逐张；重复触发合并成当前任务之后的一次重扫，不会叠出第二份全库回填。
enum AttributeBackfill {

    static let defaultBatchSize = 16

    /// 一项待回填的能力：缺哪个 key，就用哪个处理器补。
    /// 新增派生能力要参与回填 = 在 `jobs()` 里加一行。
    struct Job {
        let key: String
        let processor: CapturePostProcessor
    }

    private struct Pending: @unchecked Sendable {
        let shotID: Int64
        let url: URL
        let bundleID: String?
        var jobIndexes: [Int] = []
    }

    private struct RunConfiguration: @unchecked Sendable {
        let jobs: [Job]
        let store: any ShotReading
        let writer: any ShotAttributeWriter
        let batchSize: Int
    }

    @MainActor
    private static func jobs(styleStore: any IntelligencePreferences) -> [Job] {
        var jobs: [Job] = [
            Job(key: AttributeKey.featurePrint, processor: FeaturePrintProcessor())
        ]
        if styleStore.autoClassify {
            jobs.append(Job(key: AttributeKey.category, processor: CategoryProcessor(intelligence: styleStore)))
            jobs.append(Job(key: AttributeKey.visionLabels, processor: VisionLabelsProcessor(intelligence: styleStore)))
        }
        if styleStore.detectSensitive {
            jobs.append(Job(key: AttributeKey.sensitiveRegions, processor: SensitiveContentProcessor(intelligence: styleStore)))
        }
        // 仅在模型就绪时回填 —— 未下载时排进任务只会逐张空跑一遍。
        if styleStore.semanticSearch && CLIPModelStore.shared.isReady {
            jobs.append(Job(key: AttributeKey.clipEmbedding, processor: CLIPEmbeddingProcessor(intelligence: styleStore)))
        }
        return jobs
    }

    @MainActor
    @discardableResult
    static func runIfNeeded(
        styleStore: any IntelligencePreferences,
        store: any ShotReading = ShotStore.shared,
        injectedWriter: ShotAttributeWriter? = nil,
        coordinator: SingleFlightTaskCoordinator = .shared,
        jobsOverride: [Job]? = nil,
        batchSize: Int = defaultBatchSize
    ) -> Bool {
        precondition(batchSize > 0)
        let selectedJobs = jobsOverride ?? jobs(styleStore: styleStore)
        let effectiveWriter: ShotAttributeWriter
        if let w = injectedWriter {
            effectiveWriter = w
        } else if let fake = store as? FakeShotStore {
            effectiveWriter = ShotStoreAttributeWriter(store: fake)
        } else if let s = store as? ShotStore {
            effectiveWriter = ShotStoreAttributeWriter(store: s)
        } else {
            effectiveWriter = ShotStoreAttributeWriter()
        }

        let configuration = RunConfiguration(
            jobs: selectedJobs,
            store: store,
            writer: effectiveWriter,
            batchSize: batchSize
        )
        return coordinator.trigger {
            await execute(configuration)
        }
    }

    @MainActor
    static func cancel() {
        SingleFlightTaskCoordinator.shared.cancel()
    }

    private nonisolated static func execute(_ configuration: RunConfiguration) async {
        guard !Task.isCancelled else { return }
        let pending = await MainActor.run {
            makePending(jobs: configuration.jobs, store: configuration.store)
        }
        guard !pending.isEmpty else { return }

        NSLog("[Index] 属性回填：\(pending.count) 张待处理，每批 \(configuration.batchSize) 张")
        var batchStart = 0
        while batchStart < pending.count, !Task.isCancelled {
            let batchEnd = min(batchStart + configuration.batchSize, pending.count)
            for index in batchStart..<batchEnd {
                guard !Task.isCancelled else { break }
                await process(
                    pending[index],
                    jobs: configuration.jobs,
                    writer: configuration.writer
                )
            }
            batchStart = batchEnd
            await Task.yield()
        }
    }

    @MainActor
    private static func makePending(
        jobs: [Job],
        store: any ShotReading
    ) -> [Pending] {
        // 按截图聚合缺失项：一张图不管缺几个 key，原图只解码一次。
        // 这里只保留轻量路径与索引；像素在后台逐张加载，批次结束即释放。
        var pendingByID: [Int64: Pending] = [:]
        for (index, job) in jobs.enumerated() {
            for shot in store.shotsMissingAttribute(key: job.key) {
                guard let id = shot.id else { continue }
                pendingByID[
                    id,
                    default: Pending(
                        shotID: id,
                        url: store.originalURL(for: shot),
                        bundleID: shot.appBundleID
                    )
                ].jobIndexes.append(index)
            }
        }
        return pendingByID.values.sorted { $0.shotID < $1.shotID }
    }

    private nonisolated static func process(
        _ item: Pending,
        jobs: [Job],
        writer: any ShotAttributeWriter
    ) async {
        guard !Task.isCancelled else { return }
        guard let image = ImageCodec.load(from: item.url) else {
            // 原图丢了：分类不依赖像素，仍写入避免每次启动重扫这一张；
            // 依赖像素的 key（标签、特征指纹）只能跳过。
            if item.jobIndexes.contains(where: { jobs[$0].key == AttributeKey.category }) {
                await writer.write(
                    shotID: item.shotID,
                    key: AttributeKey.category,
                    value: .text(ShotClassifier.classify(bundleID: item.bundleID).rawValue)
                )
            }
            return
        }

        let input = PostProcessInput(
            shotID: item.shotID,
            image: image,
            appBundleID: item.bundleID,
            metadata: .empty
        )
        for index in item.jobIndexes {
            guard !Task.isCancelled else { break }
            await jobs[index].processor.process(input, writer: writer)
        }
    }
}
