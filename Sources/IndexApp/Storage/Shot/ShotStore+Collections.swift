import Foundation

// MARK: - 收藏 / 专题收藏集 / 标签
//
// 从 `ShotStore.swift` 拆出：这组方法全部是 `attributeRepository` /
// `collectionRepository` / `pageMetadataRepository` 的一行转发，不持有本地状态。
// 收藏走主文件写入分区的 `writeAttribute` / `removeAttribute`（派生属性统一落库入口）。

extension ShotStore {
    // MARK: - 收藏

    func isFavorite(shotID: Int64) -> Bool {
        favoriteIDs.contains(shotID)
    }

    func favoriteCount() -> Int {
        favoriteIDs.count
    }

    func favoritePreviews(limit: Int = 3) -> [Shot] {
        (try? attributeRepository.favoritePreviews(limit: limit)) ?? []
    }

    func toggleFavorite(_ shot: Shot) {
        guard let id = shot.id else { return }
        if isFavorite(shotID: id) {
            removeAttribute(shotID: id, key: AttributeKey.favorite)
        } else {
            // searchableText 必须是 nil：收藏是标记不是内容，进了 attributeFts
            // 会让全文搜索命中所有收藏。
            writeAttribute(
                shotID: id,
                key: AttributeKey.favorite,
                value: .data(Data([1]), searchableText: nil)
            )
        }
    }

    func setFavorite(shotIDs: [Int64], isFavorite: Bool) {
        do {
            try attributeRepository.setFavorite(shotIDs: shotIDs, isFavorite: isFavorite)
        } catch {
            NSLog("[Index] 批量修改收藏失败: \(error.localizedDescription)")
        }
    }

    // MARK: - 专题收藏集

    func collectionSummaries() -> [ShotCollectionSummary] {
        (try? collectionRepository.summaries()) ?? []
    }

    func collectionCount() -> Int {
        (try? collectionRepository.count()) ?? 0
    }

    @discardableResult
    func createCollection(name rawName: String, note: String = "") throws -> ShotCollection {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw ShotCollectionError.emptyName }
        let collection = try collectionRepository.create(
            name: name,
            note: note.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        return collection
    }

    func renameCollection(id: Int64, to rawName: String) throws {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw ShotCollectionError.emptyName }
        try collectionRepository.rename(id: id, to: name)
    }

    func deleteCollection(id: Int64) {
        do {
            try collectionRepository.delete(id: id)
        } catch {
            NSLog("[Index] 删除收藏集失败: \(error)")
            return
        }
    }

    /// 幂等加入：重复选择同一截图不会制造重复成员。
    func addToCollection(shotIDs: [Int64], collectionID: Int64) throws {
        guard !shotIDs.isEmpty else { return }
        try collectionRepository.add(shotIDs: shotIDs, to: collectionID)
    }

    func removeFromCollection(shotIDs: [Int64], collectionID: Int64) {
        guard !shotIDs.isEmpty else { return }
        do {
            try collectionRepository.remove(shotIDs: shotIDs, from: collectionID)
        } catch {
            NSLog("[Index] 移出收藏集失败: \(error)")
            return
        }
    }

    func collectionMemberships(shotIDs: [Int64]) -> [Int64: Set<Int64>] {
        (try? collectionRepository.memberships(shotIDs: shotIDs)) ?? [:]
    }

    nonisolated func collectionMembershipCountsInBackground(
        shotIDs: [Int64]
    ) async -> [Int64: Int] {
        (try? await collectionRepository.membershipCountsInBackground(shotIDs: shotIDs)) ?? [:]
    }

    nonisolated func pageMetadataInBackground(shotIDs: [Int64]) async -> ShotPageMetadata {
        (try? await pageMetadataRepository.fetchInBackground(shotIDs: shotIDs)) ?? .empty
    }

    // MARK: - 标签
    //
    // `tag` 是**多值 key**（一张图多行），绕开 `writeAttribute` —— 它的
    // default 分支是「同 key 先删后插」的单值语义，走它会把旧标签全冲掉。
    // 这里直接插行 / 按 (shotID, key, text) 精确删行，幂等靠 EXISTS 预查。

    /// 给截图加一个标签。重复添加幂等（先查 EXISTS）；空白名忽略。
    func addTag(shotID: Int64, _ tag: String) {
        let name = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        do {
            try attributeRepository.addTag(shotID: shotID, name: name)
        } catch {
            NSLog("[Index] 添加标签 \(name) 失败: \(error)")
            return
        }
    }

    /// 移除截图上的一个标签：按 (shotID, key, text) 精确删行 ——
    /// 现有 `removeAttribute` 按 key 全删，会把其它标签一起带走，不能用。
    func removeTag(shotID: Int64, _ tag: String) {
        do {
            try attributeRepository.removeTag(shotID: shotID, name: tag)
        } catch {
            NSLog("[Index] 移除标签 \(tag) 失败: \(error)")
            return
        }
    }

    /// 一张截图的全部标签，按添加顺序。
    func tags(shotID: Int64) -> [String] {
        (try? attributeRepository.tags(shotID: shotID)) ?? []
    }

    /// 现有标签及各自的截图数量，按数量降序。侧边栏和输入建议用。
    func allTags() -> [(name: String, count: Int)] {
        (try? attributeRepository.textCounts(key: AttributeKey.tag)) ?? []
    }

    /// 全局重命名标签。目标名已存在的图先删旧名行再整体 UPDATE，
    /// 避免同图同名出现两行；UPDATE 会触发 attributeFts 的同步触发器，
    /// 全文索引跟着改。侧边栏若正选中旧名，跟着切到新名。
    func renameTag(_ old: String, to new: String) {
        let name = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != old else { return }
        do {
            try attributeRepository.renameTag(old, to: name)
        } catch {
            NSLog("[Index] 重命名标签 \(old) 失败: \(error)")
            return
        }
    }

    /// 全局删除标签：只删标签行，截图本身不动。
    /// 侧边栏若正选中该标签，退回「全部」。
    func deleteTag(_ tag: String) {
        do {
            try attributeRepository.deleteTag(tag)
        } catch {
            NSLog("[Index] 删除标签 \(tag) 失败: \(error)")
            return
        }
    }
}
