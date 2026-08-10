import CoreGraphics
import Foundation

// MARK: - 批量动作
//
// 多选之后能做的事：解析选中集合、批量收藏、批量导出。
// 右键批量菜单（GalleryGrid）和多选详情栏（MultiSelectionPane）都调这里。

/// 批量动作的共用实现：右键批量菜单和多选详情栏都走这里，行为只有一份。
@MainActor
enum GalleryBatch {

    /// 按展示顺序解析当前选中集合。语义结果可能不在常规列表里，两边找齐（去重）。
    static func selectedShots(reader: ShotReading = ShotStore.shared) -> [Shot] {
        let selection = GallerySelection.shared
        let store = reader
        var picked = store.displayShots.filter { selection.isSelected($0.id) }
        let seen = Set(picked.compactMap(\.id))
        picked += store.shots.filter { shot in
            guard let id = shot.id else { return false }
            return selection.selectedIDs.contains(id) && !seen.contains(id)
        }
        return picked
    }

    /// 把截图**渲染成品**（原图 + 最新修订的标注）放进剪贴板。
    ///
    /// 复制的是成品而不是原图：图库里看到的是什么，粘出去就该是什么 ——
    /// 原图字节仍然从未被修改（非破坏式编辑，见 Storage 的文件头）。
    ///
    /// 多选时把每一张都写成一个剪贴板条目。多数接收方只取第一条，
    /// 但访达、邮件、Keynote 这类支持多条的会全部收下 —— 只放第一张
    /// 等于悄悄丢掉用户的选择。
    ///
    /// 返回成功复制的张数，供调用方判断要不要提示。
    @discardableResult
    static func copyImages(_ shots: [Shot], reader: ShotReading = ShotStore.shared, clipboard: ClipboardWriting = MacClipboard.shared) -> Int {
        let store = reader
        let images = shots.compactMap { shot -> CGImage? in
            guard let base = store.originalImage(for: shot) else { return nil }
            let layers = store.latestRevision(for: shot)?.imageLayers ?? Layers()
            return LayerRenderer.render(base: base, layers: layers)
        }
        guard !images.isEmpty else { return 0 }
        clipboard.copy(images)
        return images.count
    }

    static func allFavorited(_ shots: [Shot], reader: ShotReading = ShotStore.shared) -> Bool {
        !shots.isEmpty && shots.allSatisfy { $0.id.map(reader.isFavorite) ?? false }
    }

    /// 全部收藏 / 全部取消收藏：已经是目标状态的跳过，动作幂等。
    static func toggleFavorites(_ shots: [Shot], writer: ShotWriting = ShotStore.shared, reader: ShotReading = ShotStore.shared) {
        let store: ShotReading = reader
        let w = writer
        let targetFavorited = !allFavorited(shots, reader: reader)
        for shot in shots {
            guard let id = shot.id, store.isFavorite(shotID: id) != targetFavorited else { continue }
            w.toggleFavorite(shot)
        }
    }

    /// 后台渲染一张成品要的全部材料，主线程收集好再整体下后台。
    private struct ExportJob {
        let url: URL
        let layers: Layers<ImageSpace>
        let name: String
    }

    /// 批量导出：选目录（面板收敛在 SystemNavigator，视图里不裸跑 runModal），
    /// 逐张渲染成品（含最新标注）按文件名模板写入，
    /// 重名由 ImageExporter.writePNG 自动加 -2 / -3 … 序号。返回成功张数（取消 = 0）。
    static func exportAll(_ shots: [Shot], reader: ShotReading = ShotStore.shared) async -> Int {
        guard let directory = SystemNavigator.chooseDirectory(
            message: "选择 \(shots.count) 张截图的导出目录",
            prompt: "导出到此处",
            defaultDirectory: FileManager.default
                .urls(for: .desktopDirectory, in: .userDomainMask).first
        ) else { return 0 }

        let store = reader
        let jobs = shots.map { shot in
            ExportJob(
                url: store.originalURL(for: shot),
                layers: store.latestRevision(for: shot)?.imageLayers ?? Layers(),
                name: ImageExporter.suggestedName(for: shot)
            )
        }
        // 解码 / 渲染 / 编码 / 写盘都是重活，整体放后台，主线程不卡。
        return await Task.detached(priority: .userInitiated) {
            var exported = 0
            for job in jobs {
                guard let base = ImageCodec.load(from: job.url) else { continue }
                let rendered = LayerRenderer.render(base: base, layers: job.layers)
                guard let png = ImageCodec.pngData(from: rendered) else { continue }
                if (try? ImageExporter.writePNG(png, into: directory, preferredName: job.name)) != nil {
                    exported += 1
                }
            }
            return exported
        }.value
    }
}
