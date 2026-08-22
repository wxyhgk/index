import CoreGraphics
import Foundation

// MARK: - 批量动作
//
// 多选之后能做的事：解析选中集合、批量收藏、批量导出。
// 右键批量菜单（GalleryGrid）和多选详情栏（MultiSelectionPane）都调这里。

/// 批量动作的共用实现：右键批量菜单和多选详情栏都走这里，行为只有一份。
@MainActor
enum GalleryBatch {

    static func allFavorited(ids: [Int64]) -> Bool {
        allFavorited(ids: ids, reader: ShotStore.shared)
    }

    static func allFavorited(ids: [Int64], reader: ShotReading) -> Bool {
        !ids.isEmpty && ids.allSatisfy(reader.isFavorite)
    }

    /// 当前页已经包含全部选中项时直接按稳定顺序返回；缺任意一张就返回 nil，
    /// 调用方再走后台分块解析。这样普通单张 ⌘C 仍能同步写剪贴板，只有跨页全选才等待数据库。
    static func loadedSelectedShots(displayedShots: [Shot]? = nil) -> [Shot]? {
        loadedSelectedShots(displayedShots: displayedShots, reader: ShotStore.shared)
    }

    static func loadedSelectedShots(displayedShots: [Shot]?, reader: ShotReading) -> [Shot]? {
        let ids = GalleryWindowController.shared.selection.orderedSelectedIDs
        guard !ids.isEmpty else { return nil }
        var byID: [Int64: Shot] = [:]
        for shot in (displayedShots ?? []) + reader.shots {
            if let id = shot.id { byID[id] = shot }
        }
        let resolved = ids.compactMap { byID[$0] }
        return resolved.count == ids.count ? resolved : nil
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
    static func copyImages(_ shots: [Shot]) -> Int {
        copyImages(shots, reader: ShotStore.shared, clipboard: MacClipboard.shared)
    }

    @discardableResult
    static func copyImages(_ shots: [Shot], reader: ShotReading) -> Int {
        copyImages(shots, reader: reader, clipboard: MacClipboard.shared)
    }

    @discardableResult
    static func copyImages(
        _ shots: [Shot],
        reader: ShotReading,
        clipboard: ClipboardWriting
    ) -> Int {
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

    /// 全部收藏 / 全部取消收藏：已经是目标状态的跳过，动作幂等。
    static func toggleFavorites(ids: [Int64]) {
        toggleFavorites(ids: ids, writer: ShotStore.shared, reader: ShotStore.shared)
    }

    static func toggleFavorites(ids: [Int64], writer: ShotWriting, reader: ShotReading) {
        let targetFavorited = !allFavorited(ids: ids, reader: reader)
        writer.setFavorite(shotIDs: ids, isFavorite: targetFavorited)
    }

    @discardableResult
    static func copySelectedImages() async -> Int {
        await copyImages(
            ids: GalleryWindowController.shared.selection.orderedSelectedIDs,
            reader: ShotStore.shared,
            clipboard: MacClipboard.shared
        )
    }

    @discardableResult
    static func copySelectedImages(reader: ShotReading) async -> Int {
        await copyImages(
            ids: GalleryWindowController.shared.selection.orderedSelectedIDs,
            reader: reader,
            clipboard: MacClipboard.shared
        )
    }

    @discardableResult
    static func copySelectedImages(reader: ShotReading, clipboard: ClipboardWriting) async -> Int {
        await copyImages(
            ids: GalleryWindowController.shared.selection.orderedSelectedIDs,
            reader: reader,
            clipboard: clipboard
        )
    }

    @discardableResult
    static func copyImages(ids: [Int64]) async -> Int {
        await copyImages(ids: ids, reader: ShotStore.shared, clipboard: MacClipboard.shared)
    }

    @discardableResult
    static func copyImages(
        ids: [Int64],
        reader: ShotReading,
        clipboard: ClipboardWriting
    ) async -> Int {
        let orderedIDs = unique(ids)
        let activity = GalleryWindowController.shared.batchActivity
        guard let token = activity.begin(kind: .copy, total: orderedIDs.count) else { return 0 }
        defer { activity.finish(token: token) }

        let materials = await reader.outputMaterialsInBackground(ids: orderedIDs)
        let jobs = materials.map { RenderJob(url: $0.originalURL, layers: $0.layers) }
        let worker = Task.detached(priority: .userInitiated) {
            var images: [CGImage] = []
            images.reserveCapacity(jobs.count)
            for (index, job) in jobs.enumerated() {
                guard !Task.isCancelled else { break }
                if let image = autoreleasepool(invoking: { job.render() }) {
                    images.append(image)
                }
                await activity.update(token: token, processed: index + 1)
            }
            return RenderedImages(images: images)
        }
        activity.attachCancellation(token: token) { worker.cancel() }
        let rendered = await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
        guard !Task.isCancelled, activity.state?.isCancelling != true,
              !rendered.images.isEmpty else { return 0 }
        clipboard.copy(rendered.images)
        return rendered.images.count
    }

    /// 后台渲染一张成品要的全部材料，主线程收集好再整体下后台。
    private struct RenderJob: @unchecked Sendable {
        let url: URL
        let layers: Layers<ImageSpace>

        func render() -> CGImage? {
            guard let base = ImageCodec.load(from: url) else { return nil }
            return layers.isEmpty ? base : LayerRenderer.render(base: base, layers: layers)
        }
    }

    private struct RenderedImages: @unchecked Sendable {
        let images: [CGImage]
    }

    private struct ExportJob: @unchecked Sendable {
        let renderJob: RenderJob
        let name: String
    }

    /// 批量导出：选目录（面板收敛在 SystemNavigator，视图里不裸跑 runModal），
    /// 逐张渲染成品（含最新标注）按文件名模板写入，
    /// 重名由 ImageExporter.writePNG 自动加 -2 / -3 … 序号。返回成功张数（取消 = 0）。
    static func exportAll(ids: [Int64]) async -> Int {
        await exportAll(ids: ids, reader: ShotStore.shared)
    }

    static func exportAll(ids: [Int64], reader: ShotReading) async -> Int {
        guard !GalleryWindowController.shared.batchActivity.isBusy else { return 0 }
        guard let directory = SystemNavigator.chooseDirectory(
            message: "选择 \(ids.count) 张截图的导出目录",
            prompt: "导出到此处",
            defaultDirectory: FileManager.default
                .urls(for: .desktopDirectory, in: .userDomainMask).first
        ) else { return 0 }

        return await exportAll(ids: ids, reader: reader, directory: directory)
    }

    static func exportAll(ids: [Int64], reader: ShotReading, directory: URL) async -> Int {
        let orderedIDs = unique(ids)
        let activity = GalleryWindowController.shared.batchActivity
        guard let token = activity.begin(kind: .export, total: orderedIDs.count) else { return 0 }
        defer { activity.finish(token: token) }

        let materials = await reader.outputMaterialsInBackground(ids: orderedIDs)
        let jobs = materials.map { material in
            ExportJob(
                renderJob: RenderJob(url: material.originalURL, layers: material.layers),
                name: ImageExporter.suggestedName(for: material.shot)
            )
        }
        let worker = Task.detached(priority: .userInitiated) {
            var exported = 0
            for (index, job) in jobs.enumerated() {
                guard !Task.isCancelled else { break }
                let didWrite = autoreleasepool { () -> Bool in
                    guard let rendered = job.renderJob.render(),
                          let png = ImageCodec.pngData(from: rendered) else { return false }
                    return (try? ImageExporter.writePNG(
                        png,
                        into: directory,
                        preferredName: job.name
                    )) != nil
                }
                if didWrite {
                    exported += 1
                }
                await activity.update(token: token, processed: index + 1)
            }
            return exported
        }
        activity.attachCancellation(token: token) { worker.cancel() }
        return await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private static func unique(_ ids: [Int64]) -> [Int64] {
        var seen = Set<Int64>()
        return ids.filter { seen.insert($0).inserted }
    }
}
