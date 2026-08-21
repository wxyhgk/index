import Foundation

// MARK: - 刷新合并 / 查询观察 / 分页 / 智能筛选计数
//
// 从 `ShotStore.swift` 拆出：全 store 唯一有状态逻辑的部分 ——
// GRDB 持续观察（generation 防迟到快照发布）、游标分页
// （`loadNextPage` 追加不发 `libraryDidChange`）、侧边栏徽章聚合 SQL。
// 观察的存储属性（listObservation / generation / pendingInitialObservation）
// 留在主文件，`shots` / `favoriteIDs` / `hasMorePages` 的写访问为这个扩展放开。

extension ShotStore {
    // MARK: - 刷新合并

    /// 列表一次最多取多少行。
    ///
    /// 这是一个**临时上限**，不是设计意图：网格目前一次性拿到全部行再交给
    /// `LazyVGrid`，所以行数直接等于内存里的 `Shot` 数组长度。没有它的话，
    /// 十万张的库会在一次 `reload()` 里把十万行取回并解码。
    ///
    /// 真正的解法是**分页**（滚到底再取下一页）：那要连带改网格的滚动、
    /// 分组段头、键盘上下键的步长、以及「全选」的语义（全选是选当前这一页还是全库？），
    /// 所以单独作为一批做。在那之前，超过这个数的老截图仍然搜得到
    /// （搜索走的是同一条 SQL，只是结果也受这个上限约束）。
    ///
    /// 三条列表查询共用这一个常量 —— 此前是三处硬编码的 500，
    /// 改一处漏两处是迟早的事。
    /// `nonisolated`：它被用作 `allShots(limit:)` 的默认参数，
    /// 而默认参数在调用方的上下文里求值，可能不是主 actor。
    /// 一页多少行。
    ///
    /// 取 300：足够铺满几屏（默认缩放下一屏约 20 张），滚动时不会频繁触发下一页；
    /// 又远小于「整库」，所以第一屏的等待与库的大小无关 —— 这正是分页的意义。
    nonisolated static let pageSize = 300

    /// 下一页的游标 = 当前已加载的最后一行。nil 表示还没加载过。
    private var pageCursor: ShotQueryRepository.PageCursor? {
        shots.last.flatMap { shot in
            shot.id.map { ShotQueryRepository.PageCursor(capturedAt: shot.capturedAt, id: $0) }
        }
    }

    // MARK: - 查询

    /// 按明确的图库查询条件同步刷新。查询条件由 `GalleryViewModel` 持有；
    /// Store 只保留这份缓存来源快照，供后续写入刷新和翻页复用。
    func reload(query rawQuery: String, filter: ShotFilter) {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        restartLibraryObservation(
            request: ActiveListQuery(text: query, filter: filter),
            immediately: true
        )
    }

    /// 刷新当前缓存对应的查询。库存写入后的自动刷新与定位类调用使用。
    func reload() {
        reload(query: activeListQuery.text, filter: activeListQuery.filter)
    }

    /// 异步建立同一份持续观察，并等待首个快照发布。后续数据库提交继续由该观察驱动。
    func reloadInBackground(query rawQuery: String, filter: ShotFilter) async {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let request = ActiveListQuery(text: query, filter: filter)
        await withCheckedContinuation { continuation in
            restartLibraryObservation(
                request: request,
                immediately: false,
                onInitial: { continuation.resume() }
            )
        }
    }

    /// 异步重建当前缓存对应的观察。
    func reloadInBackground() async {
        let request = activeListQuery
        await reloadInBackground(query: request.text, filter: request.filter)
    }

    private func restartLibraryObservation(
        request: ActiveListQuery,
        immediately: Bool,
        onInitial: (() -> Void)? = nil
    ) {
        finishPendingInitialObservation()
        listObservation?.cancel()
        listObservationGeneration += 1
        let generation = listObservationGeneration
        activeListQuery = request
        pendingInitialObservation = onInitial

        listObservation = queryRepository.observeLibrary(
            query: request.text,
            filter: request.filter,
            limit: Self.pageSize,
            immediately: immediately,
            onError: { [weak self] error in
                guard let self,
                      generation == self.listObservationGeneration,
                      request == self.activeListQuery
                else { return }
                NSLog("[Index] 图库数据库观察失败: \(error)")
                self.finishPendingInitialObservation()
            },
            onChange: { [weak self] snapshot in
                guard let self,
                      generation == self.listObservationGeneration,
                      request == self.activeListQuery
                else { return }
                self.publish(shots: snapshot.shots, favorites: snapshot.favoriteIDs)
                self.finishPendingInitialObservation()
            }
        )
    }

    private func finishPendingInitialObservation() {
        let completion = pendingInitialObservation
        pendingInitialObservation = nil
        completion?()
    }

    /// 赋值 + 发通知。数据库观察的每个有效快照只走这一条发布路径。
    ///
    /// 先算好再一起赋值，整轮刷新只发一次 `objectWillChange` ——
    /// 此前 shots / favoriteIDs 两个 @Published 各发一次，订阅方级联重查两遍。
    private func publish(shots newShots: [Shot], favorites newFavoriteIDs: Set<Int64>) {
        objectWillChange.send()
        shots = newShots
        favoriteIDs = newFavoriteIDs
        // 取满一页就假定还有下一页。这会导致「总数正好是页大小整数倍」时
        // 多翻一次空页 —— 代价是一次查询，换来的是不必每轮刷新都跑一条 COUNT(*)。
        hasMorePages = newShots.count >= Self.pageSize
        libraryDidChange.send()
    }

    /// 取下一页并追加。滚到底时由网格触发。
    ///
    /// 没有下一页或正在取时直接返回 —— 触发器可以放心地多调。
    /// 语义搜索结果也天然不分页：结果 ≤30 条，小于 `pageSize`，
    /// `hasMorePages` 为 false，在这里就返回了。
    func loadNextPage() async {
        guard hasMorePages, !isLoadingPage else { return }
        guard let cursor = pageCursor else { return }

        isLoadingPage = true
        defer { isLoadingPage = false }

        let request = activeListQuery
        let page = (try? await queryRepository.shotsInBackground(
            query: request.text,
            filter: request.filter,
            after: cursor,
            limit: Self.pageSize
        )) ?? []

        // 翻页途中筛选/搜索被改过：这一页属于旧条件，丢掉。
        // （`reload` 会把 shots 换成新条件的第一页，此时游标也已经不是我们那个。）
        guard cursor == pageCursor, activeListQuery == request else { return }

        objectWillChange.send()
        shots.append(contentsOf: page)
        hasMorePages = page.count >= Self.pageSize
        // **不发 `libraryDidChange`**：库存内容没变，只是多显示了一段。
        // 发了会让胶片条无谓地重查全库（那条信号的由来见它的注释）。
    }

    /// 当前筛选 / 搜索下的**全部** ID，不受分页限制。
    ///
    /// 「全选」要的是「符合当前条件的所有截图」，而不是「已经滚出来的那些」——
    /// 后者会让同一个 ⌘A 因为你滚了多远而选中不同的东西。
    /// 只取 id 一列，十万行也就几百 KB。
    func allMatchingIDs(query rawQuery: String, filter: ShotFilter) async -> [Int64] {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return (try? await queryRepository.matchingIDsInBackground(
            query: query,
            filter: filter
        )) ?? []
    }

    nonisolated func shotsInBackground(ids: [Int64]) async -> [Shot] {
        (try? await metadataRepository.shotsInBackground(ids: ids)) ?? []
    }

    nonisolated func outputMaterialsInBackground(ids: [Int64]) async -> [ShotOutputMaterial] {
        let records = (try? await metadataRepository.outputRecordsInBackground(ids: ids)) ?? []
        return records.map { record in
            ShotOutputMaterial(
                shot: record.shot,
                originalURL: originalsDirectory.appendingPathComponent(record.shot.originalFileName),
                layers: record.layers
            )
        }
    }

    /// 语义搜索的候选范围只看固定筛选，不把自然语言查询误当成精确文本查询。
    /// 复用 `ShotQueryRepository` 的筛选 SQL，避免录屏 / 标签 / App 各写一套条件。
    func matchingShotIDsInBackground(filter: ShotFilter) async -> Set<Int64> {
        let ids = (try? await queryRepository.matchingIDsInBackground(
            query: "",
            filter: filter
        )) ?? []
        return Set(ids)
    }

    var totalCount: Int {
        (try? metadataRepository.count()) ?? 0
    }

    // MARK: - 智能筛选：时间边界与计数
    //
    // 侧边栏的四个徽章会在**每轮 store 变更后**一起重算，所以这四个查询
    // 必须各是一条聚合 SQL —— 把行取回来再在 Swift 里 count（`relatedShots`
    // 那种全表拉取）在这个调用频率下是不可接受的。

    /// 一个标签都没打过的截图数。侧边栏徽章用。
    ///
    /// `NOT EXISTS` 相关子查询走 (shotID, key) 复合索引，每张图一次索引探测；
    /// `LEFT JOIN … IS NULL` 在多值 tag 下还要额外去重，这里不用它。
    func untaggedCount() -> Int {
        (try? queryRepository.untaggedCount()) ?? 0
    }

    /// 真的标注过的截图数。侧边栏徽章用。
    ///
    /// 口径与卡片铅笔角标（`annotatedShotIDs`）、清理豁免（`cleanupCandidates`）
    /// 三处统一：修订数 > 1，即除了入库时自动建的那条「原始」空修订之外还有别的。
    /// 分组走 revision.shotID 索引，外层只数分组数，不取行。
    func annotatedCount() -> Int {
        (try? revisionRepository.annotatedCount()) ?? 0
    }

    /// 全库时间倒序，**不受** `GalleryViewModel` 查询条件影响（`shots` 是筛选后的列表）。
    /// 编辑器胶片条用：换图的心智是「库里最近截了什么」，不跟图库窗口的筛选联动。
    /// 胶片条是**横向一条**、只用来跳到最近的图，不做分页 ——
    /// 取一页的量就够，再多也滚不过来。
    func allShots(limit: Int = ShotStore.pageSize) -> [Shot] {
        (try? metadataRepository.recent(limit: limit)) ?? []
    }

    /// 记录是否还在库里。编辑器窗口用它在库变更后判断「正在编辑的 shot 被删了」。
    func shotExists(id: Int64) -> Bool {
        (try? metadataRepository.exists(id: id)) ?? false
    }

    /// 应用首页的完整聚合：稳定身份、数量、最近捕获时间和最新三张预览。
    /// 单条窗口查询只返回每个 App 最新三行，不把整库截图拉回主线程。
    func capturedApps() -> [CapturedAppSummary] {
        (try? metadataRepository.capturedApps()) ?? []
    }

    /// 现有分类及各自的截图数量，按数量降序。图库侧边栏用。
    func categories() -> [(name: String, count: Int)] {
        (try? attributeRepository.textCounts(key: AttributeKey.category)) ?? []
    }

    /// 读一条派生属性的文本值。详情页展示分类 / 标签用。
    func attributeText(shotID: Int64, key: String) -> String? {
        try? attributeRepository.text(shotID: shotID, key: key)
    }

    /// 批量读一批截图的某个文本属性。图库网格给卡片配分类胶囊用 ——
    /// 逐卡片查一次库会在滚动时反复打主线程，这里一条 IN 查询拉全量。
    func attributeTexts(key: String, shotIDs: [Int64]) -> [Int64: String] {
        (try? attributeRepository.texts(key: key, shotIDs: shotIDs)) ?? [:]
    }

    /// 一批截图里「真的标注过」（修订数 > 1，超出入库时自动建的那条「原始」）
    /// 的 ID 集合。图库网格的标注角标用，一条聚合查询。
    func annotatedShotIDs(among shotIDs: [Int64]) -> Set<Int64> {
        (try? revisionRepository.annotatedShotIDs(among: shotIDs)) ?? []
    }

    /// 读一条派生属性的二进制载荷。相似检索取目标指纹用。
    func attributePayload(shotID: Int64, key: String) -> Data? {
        try? attributeRepository.payload(shotID: shotID, key: key)
    }

    /// 某个 key 的全部二进制载荷（shotID + payload）。相似检索的候选集，一条 SQL 拉全量。
    func attributePayloads(key: String) -> [(shotID: Int64, payload: Data)] {
        (try? attributeRepository.payloads(key: key)) ?? []
    }

    /// 同上，但**在后台连接上读**。
    ///
    /// 这是相似图 / 语义搜索的入口：一次要把全库的特征向量取回来
    /// （CLIP 512 维约 2KB/张，指纹更大），几千张就是几十 MB 的 blob。
    /// 同步版本会把这几十 MB 的取回与解码全压在主线程上 —— 点一次「查找相似」
    /// 就卡一下。`DatabasePool` 的读连接与写连接互不阻塞（WAL），
    /// 所以这一趟完全不必占用主线程。
    nonisolated func attributePayloadsInBackground(
        key: String
    ) async -> [(shotID: Int64, payload: Data)] {
        (try? await attributeRepository.payloadsInBackground(key: key)) ?? []
    }

}
