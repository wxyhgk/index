import Foundation
import CoreGraphics

/// 历史数据回填：给分类功能上线之前的截图补上 `category` / `vision.labels`。
///
/// 启动时调一次 `runIfNeeded()`。utility 优先级、串行逐张 ——
/// 老图可能有几百张，宁可慢慢补，也不把机器打满。
enum AttributeBackfill {

    @MainActor
    static func runIfNeeded() {
        guard AppSettings.shared.autoClassify else { return }

        let store = ShotStore.shared
        let pending = store.shotsMissingAttribute(key: AttributeKey.category)
        guard !pending.isEmpty else { return }

        // 后台线程不能碰 @MainActor 的 ShotStore，先在主 actor 上备好路径。
        let items: [(shot: Shot, url: URL)] = pending.compactMap { shot in
            shot.id == nil ? nil : (shot, store.originalURL(for: shot))
        }

        NSLog("[MacShot] 分类回填：\(items.count) 张待处理")

        let writer = ShotStoreAttributeWriter()
        let category = CategoryProcessor()
        let visionLabels = VisionLabelsProcessor()

        Task.detached(priority: .utility) {
            for item in items {
                guard let image = ImageCodec.load(from: item.url) else {
                    // 原图丢了也写入分类，避免每次启动都重扫这一张。
                    await writer.write(
                        shotID: item.shot.id!,
                        key: AttributeKey.category,
                        value: .text(ShotClassifier.classify(bundleID: item.shot.appBundleID))
                    )
                    continue
                }
                let input = PostProcessInput(
                    shotID: item.shot.id!,
                    image: image,
                    appBundleID: item.shot.appBundleID
                )
                await category.process(input, writer: writer)
                await visionLabels.process(input, writer: writer)
            }
        }
    }
}
