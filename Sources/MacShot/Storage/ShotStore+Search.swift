import Foundation

// MARK: - 相似图 / 语义搜索 / 同源时间线 / 清理候选
//
// 从 `ShotStore.swift` 拆出：全部只读检索路径。
// 相似图 / 语义搜索的线程边界一致：候选 blob 走后台连接取回，
// 反序列化与距离计算挪到 `Task.detached`，算完回主 actor 按 ID 取 Shot。

extension ShotStore {
    // MARK: - 同源时间线

    /// 归一化网址用于同源判定：去掉 fragment、去掉尾部斜杠。
    /// 「同一页面」的语义下 `…/docs#intro` 和 `…/docs/` 都算 `…/docs`。
    static func normalizedSourceURL(_ raw: String) -> String {
        var s = raw
        if let hash = s.firstIndex(of: "#") {
            s = String(s[..<hash])
        }
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    /// 与目标同源的截图序列（**含自己**），按拍摄时间升序。判定优先级：
    ///
    /// 1. 有网址 → 归一化后相同（同一页面的演化史）
    /// 2. 否则有 bundleID + 窗口标题 → 两者都相同（同一 App 窗口）
    /// 3. 否则只有 bundleID → 同一 App
    ///
    /// 少于 2 张视为无同源，调用方据此禁用入口。
    /// 网址匹配需要归一化，SQL 表达不了，取回候选后在 Swift 里过滤 —— 数据量小，不值得更聪明。
    func relatedShots(to shot: Shot) -> [Shot] {
        if let source = shot.sourceURL {
            let target = Self.normalizedSourceURL(source)
            // 先在 SQL 里用前缀把候选缩到一小撮，再在 Swift 里做精确判定。
            //
            // 能这么做是因为归一化只**截短**（去掉 `#锚点`、去掉末尾斜杠）——
            // 归一化后的串必然是原串的前缀，所以「归一化后等于 target」的行
            // 一定满足 `sourceURL LIKE 'target%'`。反过来不成立（比如
            // target 是 `…/a`，`…/abc` 也会命中前缀），所以后面那次精确过滤不能省。
            //
            // 此前这里是 `sourceURL IS NOT NULL` —— **把全库带网址的行整个取回来**
            // 再在 Swift 里筛，而它挂在详情栏上，每选一张卡片就跑一次。
            // 几千张浏览器截图时这是明显的卡顿源（审计记录在案的重灾区）。
            let candidates = (try? metadataRepository.relatedBySourcePrefix(target)) ?? []
            return candidates
                .filter { $0.sourceURL.map(Self.normalizedSourceURL) == target }
        }
        if let bundleID = shot.appBundleID {
            return (try? metadataRepository.related(
                bundleID: bundleID,
                windowTitle: shot.windowTitle
            )) ?? []
        }
        return []
    }

    // MARK: - 语义搜索

    /// 按自然语言描述搜截图：查询文本过 CLIP 文本编码器，
    /// 与全部图像向量算余弦相似度（向量已归一化，等于点积），降序取前 `limit` 张。
    ///
    /// 线程边界与 `similarShots` 相同：候选载荷在主 actor 上一次性拉出，
    /// 反序列化和点积挪到后台，算完回主 actor 按 ID 取 Shot。
    /// 全量线性扫描，512 维 × 几千张在毫秒量级。
    func semanticSearch(
        query: String,
        limit: Int = 30,
        filter: ShotFilter = .all
    ) async -> [Shot] {
        guard let queryVector = await CLIPEncoder.shared.embedText(query) else { return [] }

        // 固定 destination / 普通筛选都必须约束候选集。先用共用筛选 SQL 得到
        // 允许 ID，再从后台取回的向量中求交；不能先取全库 top 30 再过滤，
        // 否则录屏较少时会错误地得到空结果。
        let allowedIDs: Set<Int64>?
        if filter == .all {
            allowedIDs = nil
        } else {
            allowedIDs = await matchingShotIDsInBackground(filter: filter)
        }
        let allCandidates = await attributePayloadsInBackground(key: AttributeKey.clipEmbedding)
        let candidates = allowedIDs.map { allowed in
            allCandidates.filter { allowed.contains($0.shotID) }
        } ?? allCandidates
        guard !candidates.isEmpty else { return [] }

        let rankedIDs = await Task.detached(priority: .userInitiated) { () -> [Int64] in
            var scored: [(shotID: Int64, similarity: Float)] = []
            scored.reserveCapacity(candidates.count)
            for candidate in candidates {
                // 载荷损坏或维度不匹配（未来换模型）的直接跳过。
                guard let vector = CLIPEncoder.vector(from: candidate.payload),
                      vector.count == queryVector.count
                else { continue }
                scored.append((candidate.shotID, CLIPEncoder.dot(queryVector, vector)))
            }
            return scored
                .sorted { $0.similarity > $1.similarity }
                .prefix(limit)
                .map(\.shotID)
        }.value
        guard !rankedIDs.isEmpty else { return [] }

        let fetched = shots(ids: rankedIDs)
        let byID = Dictionary(uniqueKeysWithValues: fetched.compactMap { s in s.id.map { ($0, s) } })
        // IN 查询不保序，按相似度降序重排。
        return rankedIDs.compactMap { byID[$0] }
    }

    /// 按 ID 批量取 Shot。同步方法，避免在 async 上下文里误触 GRDB 的 async read 重载。
    private func shots(ids: [Int64]) -> [Shot] {
        (try? metadataRepository.shots(ids: ids)) ?? []
    }

    /// 自动清理的候选：拍摄早于 `cutoff`、未收藏、没加入专题集、没打过标签、
    /// 没有原始附件，且从未标注过。
    ///
    /// 「从未标注过」= 修订数 ≤ 1，即只有入库时自动建的那条「原始」空修订 ——
    /// 截图时标注、钉图上画、编辑器里改，任何一笔都会追加修订、让计数超过 1，
    /// 从而永久脱离清理范围。打过标签同理豁免 —— 用户亲手组织过的图，
    /// 就是在说「我在意它」。按时间升序：一批删不完时先删最老的，剩下的留给下次。
    func cleanupCandidates(olderThan cutoff: Date, limit: Int) -> [Shot] {
        (try? queryRepository.cleanupCandidates(olderThan: cutoff, limit: limit)) ?? []
    }

    /// 还没有指定 key 属性的截图。启动回填用。
    func shotsMissingAttribute(key: String) -> [Shot] {
        (try? attributeRepository.shotsMissing(key: key)) ?? []
    }

    /// 与目标视觉最相似的截图，按特征指纹距离升序取前 `limit` 张。
    ///
    /// 线程边界：目标载荷同步读取，候选载荷通过属性仓储的后台连接拉出，
    /// 反序列化和距离计算这类 CPU 活挪到后台，算完回主 actor 按 ID 取 Shot。
    /// 全量线性扫描 —— 两千张以内毫无压力，更大的库需要上向量索引再优化。
    func similarShots(to shot: Shot, limit: Int = 12) async -> [Shot] {
        guard let targetID = shot.id,
              let targetData = attributePayload(shotID: targetID, key: AttributeKey.featurePrint)
        else { return [] }

        // 后台取 blob：几千张时这是几十 MB，同步读会把主线程按住。
        let candidates = await attributePayloadsInBackground(key: AttributeKey.featurePrint)
            .filter { $0.shotID != targetID }
        guard !candidates.isEmpty else { return [] }

        let rankedIDs = await Task.detached(priority: .userInitiated) { () -> [Int64] in
            guard let target = FeaturePrint.observation(from: targetData) else { return [] }
            var scored: [(shotID: Int64, distance: Float)] = []
            scored.reserveCapacity(candidates.count)
            for candidate in candidates {
                // 解档失败或指纹版本不兼容的直接跳过。
                guard let observation = FeaturePrint.observation(from: candidate.payload),
                      let distance = FeaturePrint.distance(target, to: observation)
                else { continue }
                scored.append((candidate.shotID, distance))
            }
            return scored
                .sorted { $0.distance < $1.distance }
                .prefix(limit)
                .map(\.shotID)
        }.value
        guard !rankedIDs.isEmpty else { return [] }

        let fetched = shots(ids: rankedIDs)
        let byID = Dictionary(uniqueKeysWithValues: fetched.compactMap { s in s.id.map { ($0, s) } })
        // IN 查询不保序，按距离升序重排。
        return rankedIDs.compactMap { byID[$0] }
    }
}
