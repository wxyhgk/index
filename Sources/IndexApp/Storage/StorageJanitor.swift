import Foundation

/// 启动时的存储清理：删掉「超过保留天数、未收藏、没打过标签、且从未标注过」的旧截图。
///
/// 修订链的价值反过来定义了什么值得留 —— 收藏的、打过标签的和标注过的永远不删。
/// 「从未标注过」由修订数判定（≤ 1，只有入库时的「原始」空修订），
/// 判定 SQL 在 `ShotStore.cleanupCandidates`；删除走 `ShotStore.delete`，
/// 复用它的内容寻址引用计数逻辑，不会误删被其它记录共享的原图文件。
enum StorageJanitor {

    /// 单次启动最多删这么多张 —— 首次开启时可能积压上千张候选，
    /// 一口气全删会卡启动。删不完的下次启动接着删。
    static let batchLimit = 200

    @MainActor
    static func runIfNeeded(
        settings: any LibraryPreferences,
        store: any ShotReading & ShotWriting = ShotStore.shared
    ) {
        guard settings.autoCleanupEnabled else { return }

        let days = settings.autoCleanupDays
        guard days > 0 else { return }
        let cutoff = Date().addingTimeInterval(-TimeInterval(days) * 86_400)

        let candidates = store.cleanupCandidates(olderThan: cutoff, limit: batchLimit)
        guard !candidates.isEmpty else { return }

        // 单事务批量删除：逐张删会在启动时打出最多 batchLimit 轮全量 reload。
        store.delete(candidates)
        NSLog("[Index] 存储清理：删除 \(candidates.count) 张（超过 \(days) 天、未收藏、无标签、未标注）")
    }
}
