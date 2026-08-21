import Foundation
import GRDB

// ============================================================
// MARK: - 剪贴板历史
//
// 记录用户复制过的内容（文本 / 图片 / 文件），供浮动面板快速回取。
//
// 设计要点：
//   · contentHash 唯一索引做去重——同一内容再次复制只刷新 capturedAt，
//     不新增行（Paste 的核心行为）。
//   · 图片条目复用 sha256 内容寻址（与图库 originals/ 同算法），
//     剪贴板里的截图和图库条目天然可关联。
//   · 图片落盘在 clipboard/ 子目录（不进 originals/，避免和图库去重混淆——
//     图库的 sha 是「成品图」的哈希，剪贴板的是「原始复制」的哈希）。
// ============================================================

/// 剪贴板条目的内容种类。
enum ClipboardHistoryKind: String, Codable {
    case text
    case image
    case file
}

struct ClipboardHistoryItem: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Equatable {
    static let databaseTableName = "clipboardHistory"

    var id: Int64?
    var kind: ClipboardHistoryKind
    var contentHash: String
    var text: String?
    var assetPath: String?
    var summary: String?
    var sourceApp: String?
    var pinned: Bool
    var capturedAt: Date
    var lastUsedAt: Date?
    var title: String?
    var isFavorite: Bool

    /// 展示名：用户起的 title 优先，否则回退 summary。
    var displayName: String {
        if let title, !title.isEmpty { return title }
        return summary ?? "未命名"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// 剪贴板条目 → 专题收藏集的关联行。
struct ClipboardCollectionItem: Codable, FetchableRecord, PersistableRecord, Equatable {
    static let databaseTableName = "clipboardCollectionItem"

    var collectionID: Int64
    var clipboardID: Int64
    var addedAt: Date
}

// MARK: - 仓库

/// 剪贴板历史的读写。非 MainActor：写入走 DatabasePool，不阻塞主线程。
final class ClipboardHistoryStore: @unchecked Sendable {

    static let shared: ClipboardHistoryStore = {
        do {
            return try ClipboardHistoryStore()
        } catch {
            fatalError("无法打开剪贴板历史存储: \(error)")
        }
    }()

    private let writer: any DatabaseWriter
    /// 图片落盘目录（Application Support/Index/clipboard/）。
    let assetDirectory: URL

    init(writer: (any DatabaseWriter)? = nil) throws {
        if let writer {
            self.writer = writer
        } else {
            let base = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Index", isDirectory: true)
            self.writer = try AppDatabase.makeWriter(at: base.appendingPathComponent("index.sqlite"))
        }
        let assetBase = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Index", isDirectory: true)
            .appendingPathComponent("clipboard", isDirectory: true)
        try FileManager.default.createDirectory(at: assetBase, withIntermediateDirectories: true)
        self.assetDirectory = assetBase
    }

    // MARK: 写入（去重）

    /// 记录一条剪贴板内容。相同 contentHash 已存在时只刷新时间，返回 false。
    /// - Returns: 是否新增了条目（false = 去重命中，仅刷新）。
    @discardableResult
    func record(
        kind: ClipboardHistoryKind,
        contentHash: String,
        text: String?,
        assetPath: String?,
        summary: String?,
        sourceApp: String?
    ) throws -> Bool {
        try writer.write { db in
            let existing = try ClipboardHistoryItem
                .filter(Column("contentHash") == contentHash)
                .fetchOne(db)
            let now = Date()
            if let existing {
                var updated = existing
                updated.capturedAt = now
                try updated.update(db)
                return false
            }
            var item = ClipboardHistoryItem(
                id: nil,
                kind: kind,
                contentHash: contentHash,
                text: text,
                assetPath: assetPath,
                summary: summary,
                sourceApp: sourceApp,
                pinned: false,
                capturedAt: now,
                lastUsedAt: nil,
                title: nil,
                isFavorite: false
            )
            try item.insert(db)
            return true
        }
    }

    /// 把图片字节落盘到 clipboard/ 目录（内容寻址），返回相对路径。
    /// 已存在同 sha 文件时不重写。
    func writeImageAsset(_ data: Data, sha: String) throws -> String {
        let url = assetDirectory.appendingPathComponent("\(sha).png")
        if !FileManager.default.fileExists(atPath: url.path) {
            try data.write(to: url, options: .atomic)
        }
        return url.lastPathComponent
    }

    // MARK: 查询

    /// 按时间倒序取最近 limit 条；query 非空时按 title/summary/text 模糊过滤。
    func recent(limit: Int = 100, query: String? = nil) throws -> [ClipboardHistoryItem] {
        try writer.read { db in
            var request = ClipboardHistoryItem
                .order(Column("capturedAt").desc)
                .limit(limit)
            if let query, !query.isEmpty {
                let pattern = "%\(query)%"
                request = request.filter(
                    Column("title").like(pattern)
                        || Column("summary").like(pattern)
                        || Column("text").like(pattern)
                )
            }
            return try request.fetchAll(db)
        }
    }

    /// 收藏的条目（收藏 tab 的剪贴板 section 用），按时间倒序。
    func favorites(limit: Int = 100) throws -> [ClipboardHistoryItem] {
        try writer.read { db in
            try ClipboardHistoryItem
                .filter(Column("isFavorite") == true)
                .order(Column("capturedAt").desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    /// 某专题集里的剪贴板成员（收藏 tab 打开专题集时展示），按加入时间倒序。
    func items(inCollection collectionID: Int64) throws -> [ClipboardHistoryItem] {
        try writer.read { db in
            try ClipboardHistoryItem.fetchAll(db, sql: """
                SELECT h.* FROM clipboardHistory h
                JOIN clipboardCollectionItem c ON c.clipboardID = h.id
                WHERE c.collectionID = ?
                ORDER BY h.capturedAt DESC
                """, arguments: StatementArguments([collectionID]))
        }
    }

    /// 某条目的完整内容（文本全文 / 图片文件 URL）。
    func content(of item: ClipboardHistoryItem) -> (text: String?, assetURL: URL?) {
        switch item.kind {
        case .text:
            return (item.text, nil)
        case .image, .file:
            guard let assetPath = item.assetPath else { return (nil, nil) }
            return (nil, assetDirectory.appendingPathComponent(assetPath))
        }
    }

    // MARK: 更新 / 删除

    func markUsed(_ item: ClipboardHistoryItem) {
        try? writer.write { db in
            var updated = item
            updated.lastUsedAt = Date()
            try updated.update(db)
        }
    }

    func setPinned(_ pinned: Bool, for item: ClipboardHistoryItem) {
        try? writer.write { db in
            var updated = item
            updated.pinned = pinned
            try updated.update(db)
        }
    }

    func rename(_ title: String?, for item: ClipboardHistoryItem) {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        try? writer.write { db in
            var updated = item
            updated.title = (trimmed?.isEmpty == false) ? trimmed : nil
            try updated.update(db)
        }
    }

    func setFavorite(_ favorite: Bool, for item: ClipboardHistoryItem) {
        try? writer.write { db in
            var updated = item
            updated.isFavorite = favorite
            try updated.update(db)
        }
    }

    func delete(_ item: ClipboardHistoryItem) {
        // 图片资产文件一并清理（文本条目没有文件）。
        if let assetPath = item.assetPath {
            try? FileManager.default.removeItem(
                at: assetDirectory.appendingPathComponent(assetPath)
            )
        }
        try? writer.write { db in
            // 级联清理收藏集关联行，避免孤儿数据。
            if let id = item.id {
                try db.execute(
                    sql: "DELETE FROM clipboardCollectionItem WHERE clipboardID = ?",
                    arguments: [id]
                )
            }
            var mutable = item
            _ = try mutable.delete(db)
        }
    }

    /// 清理超过 days 天的未固定、未收藏条目（设置里的保留策略）。
    func prune(olderThanDays days: Int) {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        try? writer.write { db in
            let stale = try ClipboardHistoryItem
                .filter(Column("capturedAt") < cutoff
                    && Column("pinned") == false
                    && Column("isFavorite") == false)
                .fetchAll(db)
            for item in stale {
                if let assetPath = item.assetPath {
                    try? FileManager.default.removeItem(
                        at: assetDirectory.appendingPathComponent(assetPath)
                    )
                }
                var mutable = item
                _ = try mutable.delete(db)
            }
        }
    }

    // MARK: 专题收藏集关联

    /// 幂等加入：重复 (collectionID, clipboardID) 不生成重复行。
    /// 跨域写入：剪贴板条目和截图条目是两种成员关系表，但共享
    /// shotCollection.updatedAt 用于收藏 tab 排序，这里直接 UPDATE。
    func addToCollection(clipboardID: Int64, collectionID: Int64) throws {
        try writer.write { db in
            let now = Date()
            try db.execute(sql: """
                INSERT OR IGNORE INTO clipboardCollectionItem
                    (collectionID, clipboardID, addedAt)
                VALUES (?, ?, ?)
                """, arguments: [collectionID, clipboardID, now])
            try db.execute(
                sql: "UPDATE shotCollection SET updatedAt = ? WHERE id = ?",
                arguments: [now, collectionID]
            )
        }
    }

    func removeFromCollection(clipboardID: Int64, collectionID: Int64) {
        try? writer.write { db in
            try db.execute(sql: """
                DELETE FROM clipboardCollectionItem
                WHERE collectionID = ? AND clipboardID = ?
                """, arguments: [collectionID, clipboardID])
            try db.execute(
                sql: "UPDATE shotCollection SET updatedAt = ? WHERE id = ?",
                arguments: [Date(), collectionID]
            )
        }
    }

    /// 批量查询剪贴板条目的收藏集成员关系。
    func collectionMemberships(clipboardIDs: [Int64]) -> [Int64: Set<Int64>] {
        let ids = Array(Set(clipboardIDs))
        guard !ids.isEmpty else { return [:] }
        return (try? writer.read { db in
            var result: [Int64: Set<Int64>] = [:]
            for start in stride(from: 0, to: ids.count, by: 500) {
                let chunk = Array(ids[start..<min(start + 500, ids.count)])
                let rows = try Row.fetchAll(db, sql: """
                    SELECT clipboardID, collectionID FROM clipboardCollectionItem
                    WHERE clipboardID IN (\(chunk.map { _ in "?" }.joined(separator: ",")))
                    """, arguments: StatementArguments(chunk))
                for row in rows {
                    let clipboardID: Int64 = row["clipboardID"]
                    let collectionID: Int64 = row["collectionID"]
                    result[clipboardID, default: []].insert(collectionID)
                }
            }
            return result
        }) ?? [:]
    }
}
