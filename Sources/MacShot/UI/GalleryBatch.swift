import Foundation

// MARK: - 批量动作
//
// 多选之后能做的事：解析选中集合、批量收藏、批量导出。
// 右键批量菜单（GalleryGrid）和多选详情栏（MultiSelectionPane）都调这里。

/// 批量动作的共用实现：右键批量菜单和多选详情栏都走这里，行为只有一份。
@MainActor
enum GalleryBatch {

    /// 按展示顺序解析当前选中集合。语义结果可能不在常规列表里，两边找齐（去重）。
    static func selectedShots() -> [Shot] {
        let selection = GallerySelection.shared
        let store = ShotStore.shared
        var picked = store.displayShots.filter { selection.isSelected($0.id) }
        let seen = Set(picked.compactMap(\.id))
        picked += store.shots.filter { shot in
            guard let id = shot.id else { return false }
            return selection.selectedIDs.contains(id) && !seen.contains(id)
        }
        return picked
    }

    static func allFavorited(_ shots: [Shot]) -> Bool {
        !shots.isEmpty && shots.allSatisfy { $0.id.map(ShotStore.shared.isFavorite) ?? false }
    }

    /// 全部收藏 / 全部取消收藏：已经是目标状态的跳过，动作幂等。
    static func toggleFavorites(_ shots: [Shot]) {
        let store = ShotStore.shared
        let targetFavorited = !allFavorited(shots)
        for shot in shots {
            guard let id = shot.id, store.isFavorite(shotID: id) != targetFavorited else { continue }
            store.toggleFavorite(shot)
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
    static func exportAll(_ shots: [Shot]) async -> Int {
        guard let directory = SystemNavigator.chooseDirectory(
            message: "选择 \(shots.count) 张截图的导出目录",
            prompt: "导出到此处",
            defaultDirectory: FileManager.default
                .urls(for: .desktopDirectory, in: .userDomainMask).first
        ) else { return 0 }

        let store = ShotStore.shared
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
