import SwiftUI

// MARK: - 快照刷新与分页
//
// 从 `GalleryGrid.swift` 拆出：这一组方法负责「可见集合 → 分组 + 元数据快照」
// 的异步刷新、无限分页触发、以及选中项的专题集成员数刷新。
// 它们只写页面派生状态（sections / metadataSnapshot / 成员数），
// 不碰 ViewModel 的查询状态与 ShotStore 的游标页。

extension GalleryGrid {

    /// 无限滚动的触发器：快滚到已加载内容的末尾时，去取下一页。
    ///
    /// 用「倒数第几张出现」而不是「最后一张出现」：等最后一张露面才开始查，
    /// 用户会看见一次空白等待。提前一屏（约 12 张）取，滚动是连续的。
    ///
    /// 触发器可以放心地多调 —— `loadNextPage` 自己挡住了「没有下一页 / 正在取」
    /// 两种情况，所以这里不需要再记状态。
    func loadMoreIfNeeded(reaching shot: Shot) {
        let loaded = store.shots
        guard loaded.count >= 12,
              let index = loaded.firstIndex(where: { $0.id == shot.id }),
              index >= loaded.count - 12 else { return }
        sessionLifecycle.runIfAbsent(.nextPage) {
            await viewModel.loadNextPage()
        }
    }

    /// 关窗后释放可从当前查询重建的页面派生快照。不动 ViewModel 的
    /// search/filter/semantic 状态，也不裁剪 ShotStore 的游标页：后者和持续观察
    /// 绑在一起，没有“保留查询快照但只丢后续页”的仓储接口，不在 UI 偷改。
    func releaseSessionDerivedSnapshots() {
        metadataGeneration &+= 1
        sections = []
        metadataSnapshot = .empty
        selectedCollectionMembershipCounts = [:]
        selectedCollectionSnapshotGeneration = -1
        timelineShot = nil
        similarShot = nil
    }

    func refreshGridSnapshot(forceFullMetadata: Bool = false) async {
        let shots = visibleShots
        let ids = shots.compactMap(\.id)
        let previous = metadataSnapshot
        let isPureAppend = !forceFullMetadata
            && !previous.shotIDs.isEmpty
            && ids.count > previous.shotIDs.count
            && ids.starts(with: previous.shotIDs)

        // 纯追加（分页）：只对新增 shots 做分组，合并到已有 sections 尾部。
        // 避免整体重建 sections 导致全网格 ForEach diff + body 重算。
        if presentation.semanticMode, presentation.semanticResults != nil {
            sections = shots.isEmpty
                ? []
                : [ShotSection(id: "语义", title: "按相似度排序", shots: shots)]
        } else if isPureAppend, !sections.isEmpty {
            let newShots = Array(shots.dropFirst(previous.shotIDs.count))
            sections = ShotSection.mergeAppend(existing: sections, newShots: newShots)
        } else {
            sections = ShotSection.group(shots)
        }

        if !hasReportedFirstPage, !shots.isEmpty {
            hasReportedFirstPage = true
            GalleryPerformance.firstPagePublished(count: shots.count)
        }

        let requestedIDs = isPureAppend
            ? Array(ids.dropFirst(previous.shotIDs.count))
            : ids
        metadataGeneration &+= 1
        let generation = metadataGeneration
        let fetched = await store.pageMetadataInBackground(shotIDs: requestedIDs)
        guard !Task.isCancelled,
              generation == metadataGeneration,
              ids == visibleShots.compactMap(\.id)
        else { return }
        let metadata = isPureAppend && metadataSnapshot.shotIDs == previous.shotIDs
            ? previous.metadata.merging(fetched)
            : fetched
        metadataSnapshot = GalleryGridMetadataSnapshot(shotIDs: ids, metadata: metadata)
    }

    func refreshSelectedCollectionMemberships() async {
        let generation = selection.generation
        let ids = selection.orderedSelectedIDs
        let counts = await store.collectionMembershipCountsInBackground(shotIDs: ids)
        guard !Task.isCancelled, generation == selection.generation else { return }
        selectedCollectionMembershipCounts = counts
        selectedCollectionSnapshotGeneration = generation
    }
}