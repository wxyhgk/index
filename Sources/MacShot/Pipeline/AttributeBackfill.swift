import Foundation
import CoreGraphics

/// 历史数据回填：给某项派生能力上线之前的截图补上对应属性
/// （`category` / `vision.labels` / `vision.featureprint`）。
///
/// 启动时调一次 `runIfNeeded()`。utility 优先级、串行逐张 ——
/// 老图可能有几百张，宁可慢慢补，也不把机器打满。
enum AttributeBackfill {

    /// 一项待回填的能力：缺哪个 key，就用哪个处理器补。
    /// 新增派生能力要参与回填 = 在 `jobs()` 里加一行。
    private struct Job {
        let key: String
        let processor: CapturePostProcessor
    }

    @MainActor
    private static func jobs() -> [Job] {
        var jobs: [Job] = [
            Job(key: AttributeKey.featurePrint, processor: FeaturePrintProcessor())
        ]
        if AppSettings.shared.autoClassify {
            jobs.append(Job(key: AttributeKey.category, processor: CategoryProcessor()))
            jobs.append(Job(key: AttributeKey.visionLabels, processor: VisionLabelsProcessor()))
        }
        if AppSettings.shared.detectSensitive {
            jobs.append(Job(key: AttributeKey.sensitiveRegions, processor: SensitiveContentProcessor()))
        }
        // 仅在模型就绪时回填 —— 未下载时排进任务只会逐张空跑一遍。
        if AppSettings.shared.semanticSearch && CLIPModelStore.shared.isReady {
            jobs.append(Job(key: AttributeKey.clipEmbedding, processor: CLIPEmbeddingProcessor()))
        }
        return jobs
    }

    @MainActor
    static func runIfNeeded() {
        let store = ShotStore.shared
        let jobs = jobs()

        // 按截图聚合缺失项：一张图不管缺几个 key，原图只解码一次。
        // 后台线程不能碰 @MainActor 的 ShotStore，先在主 actor 上备好路径。
        struct Pending {
            let shotID: Int64
            let url: URL
            let bundleID: String?
            var jobIndexes: [Int] = []
        }
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
        guard !pendingByID.isEmpty else { return }

        // 按时间无关的稳定顺序处理即可，这里保持字典自然序。
        let pending = Array(pendingByID.values)
        NSLog("[MacShot] 属性回填：\(pending.count) 张待处理")

        let writer = ShotStoreAttributeWriter()

        Task.detached(priority: .utility) {
            for item in pending {
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
                    continue
                }
                let input = PostProcessInput(
                    shotID: item.shotID,
                    image: image,
                    appBundleID: item.bundleID
                )
                for index in item.jobIndexes {
                    await jobs[index].processor.process(input, writer: writer)
                }
            }
        }
    }
}
