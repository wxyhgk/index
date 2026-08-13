import Foundation
import GRDB

/// `shotAttribute`、标签以及 Shot 一等文本属性的数据库入口。
///
/// 通用派生属性是单值 key，写入时替换旧行；标签是多值 key，必须走独立方法。
/// 该类型不持有筛选与发布状态，调用方负责在写入后刷新图库。
struct ShotAttributeRepository {
    private let database: any DatabaseWriter

    init(database: any DatabaseWriter) {
        self.database = database
    }

    // MARK: - 一等 Shot 文本

    func updateOCRText(_ text: String, shotID: Int64) throws {
        try database.write { db in
            try db.execute(
                sql: "UPDATE shot SET ocrText = ? WHERE id = ?",
                arguments: [text, shotID]
            )
        }
    }

    func updateSourceURL(_ sourceURL: String, shotID: Int64) throws {
        try database.write { db in
            try db.execute(
                sql: "UPDATE shot SET sourceURL = ? WHERE id = ?",
                arguments: [sourceURL, shotID]
            )
        }
    }

    // MARK: - 单值派生属性

    func replaceSingle(
        shotID: Int64,
        key: String,
        text: String?,
        payload: Data?
    ) throws {
        var record = ShotAttribute(
            id: nil,
            shotID: shotID,
            key: key,
            text: text,
            payload: payload,
            createdAt: Date()
        )
        try database.write { db in
            try ShotAttribute
                .filter(Column("shotID") == shotID && Column("key") == key)
                .deleteAll(db)
            try record.insert(db)
        }
    }

    func remove(shotID: Int64, key: String) throws {
        try database.write { db in
            _ = try ShotAttribute
                .filter(Column("shotID") == shotID && Column("key") == key)
                .deleteAll(db)
        }
    }

    func text(shotID: Int64, key: String) throws -> String? {
        try database.read { db in
            try String.fetchOne(db, sql: """
                SELECT text FROM shotAttribute WHERE shotID = ? AND key = ? LIMIT 1
                """, arguments: [shotID, key])
        }
    }

    func texts(key: String, shotIDs: [Int64]) throws -> [Int64: String] {
        guard !shotIDs.isEmpty else { return [:] }
        let rows = try database.read { db in
            try ShotAttribute
                .filter(Column("key") == key && shotIDs.contains(Column("shotID")))
                .fetchAll(db)
        }
        return rows.reduce(into: [:]) { result, row in
            if let text = row.text { result[row.shotID] = text }
        }
    }

    func payload(shotID: Int64, key: String) throws -> Data? {
        try database.read { db in
            try Data.fetchOne(db, sql: """
                SELECT payload FROM shotAttribute
                WHERE shotID = ? AND key = ? AND payload IS NOT NULL LIMIT 1
                """, arguments: [shotID, key])
        }
    }

    func payloads(key: String) throws -> [(shotID: Int64, payload: Data)] {
        try database.read { db in
            try Self.fetchPayloads(db, key: key)
        }
    }

    func payloadsInBackground(
        key: String
    ) async throws -> [(shotID: Int64, payload: Data)] {
        try await database.read { db in
            try Self.fetchPayloads(db, key: key)
        }
    }

    func shotsMissing(key: String) throws -> [Shot] {
        try database.read { db in
            try Shot.fetchAll(db, sql: """
                SELECT shot.* FROM shot
                WHERE shot.id NOT IN (
                    SELECT shotID FROM shotAttribute WHERE key = ?
                )
                ORDER BY shot.capturedAt DESC
                """, arguments: [key])
        }
    }

    // MARK: - 收藏

    func favoriteIDs() throws -> Set<Int64> {
        try database.read { db in
            Set(try Int64.fetchAll(db, sql: """
                SELECT shotID FROM shotAttribute WHERE key = ?
                """, arguments: [AttributeKey.favorite]))
        }
    }

    func favoriteIDsInBackground() async throws -> Set<Int64> {
        try await database.read { db in
            Set(try Int64.fetchAll(db, sql: """
                SELECT shotID FROM shotAttribute WHERE key = ?
                """, arguments: [AttributeKey.favorite]))
        }
    }

    func favoritePreviews(limit: Int) throws -> [Shot] {
        try database.read { db in
            try Shot.fetchAll(db, sql: """
                SELECT shot.* FROM shot
                WHERE EXISTS (
                    SELECT 1 FROM shotAttribute
                    WHERE shotID = shot.id AND key = ?
                )
                ORDER BY shot.capturedAt DESC, shot.id DESC
                LIMIT ?
                """, arguments: [AttributeKey.favorite, limit])
        }
    }

    /// 一次事务设置一批收藏标记。先分块清掉旧值，再按仍存在的 Shot 插入一行，
    /// 避免 ⌘A 后逐张提交导致 ValueObservation 和 WAL 被成百上千次唤醒。
    func setFavorite(shotIDs: [Int64], isFavorite: Bool) throws {
        let ids = Array(Set(shotIDs))
        guard !ids.isEmpty else { return }

        try database.write { db in
            for start in stride(from: 0, to: ids.count, by: 500) {
                let chunk = Array(ids[start..<min(start + 500, ids.count)])
                try db.execute(sql: """
                    DELETE FROM shotAttribute
                    WHERE key = ? AND shotID IN (\(chunk.map { _ in "?" }.joined(separator: ",")))
                    """, arguments: StatementArguments([AttributeKey.favorite] + chunk))
            }

            guard isFavorite else { return }
            let insert = try db.makeStatement(sql: """
                INSERT INTO shotAttribute (shotID, key, text, payload, createdAt)
                SELECT ?, ?, NULL, ?, ?
                WHERE EXISTS (SELECT 1 FROM shot WHERE id = ?)
                """)
            let now = Date()
            for id in ids {
                try insert.execute(arguments: [
                    id,
                    AttributeKey.favorite,
                    Data([1]),
                    now,
                    id,
                ])
            }
        }
    }

    // MARK: - 标签

    /// 同一张图重复添加同名标签时幂等。
    func addTag(shotID: Int64, name: String) throws {
        try database.write { db in
            let exists = try Bool.fetchOne(db, sql: """
                SELECT EXISTS (
                    SELECT 1 FROM shotAttribute
                    WHERE shotID = ? AND key = ? AND text = ?
                )
                """, arguments: [shotID, AttributeKey.tag, name]) ?? false
            guard !exists else { return }
            var record = ShotAttribute(
                id: nil,
                shotID: shotID,
                key: AttributeKey.tag,
                text: name,
                payload: nil,
                createdAt: Date()
            )
            try record.insert(db)
        }
    }

    func removeTag(shotID: Int64, name: String) throws {
        try database.write { db in
            _ = try ShotAttribute
                .filter(
                    Column("shotID") == shotID
                        && Column("key") == AttributeKey.tag
                        && Column("text") == name
                )
                .deleteAll(db)
        }
    }

    func tags(shotID: Int64) throws -> [String] {
        try database.read { db in
            try String.fetchAll(db, sql: """
                SELECT text FROM shotAttribute
                WHERE shotID = ? AND key = ? AND text IS NOT NULL
                ORDER BY id ASC
                """, arguments: [shotID, AttributeKey.tag])
        }
    }

    func textCounts(key: String) throws -> [(name: String, count: Int)] {
        try database.read { db in
            try Row.fetchAll(db, sql: """
                SELECT text AS name, COUNT(*) AS count FROM shotAttribute
                WHERE key = ? AND text IS NOT NULL
                GROUP BY text
                ORDER BY count DESC, name ASC
                """, arguments: [key])
                .map { (name: $0["name"] as String, count: $0["count"] as Int) }
        }
    }

    /// 目标名已存在的截图先删旧名，避免合并后出现同名重复行。
    func renameTag(_ oldName: String, to newName: String) throws {
        try database.write { db in
            try db.execute(sql: """
                DELETE FROM shotAttribute
                WHERE key = :key AND text = :old AND shotID IN (
                    SELECT shotID FROM shotAttribute WHERE key = :key AND text = :new
                )
                """, arguments: [
                    "key": AttributeKey.tag,
                    "old": oldName,
                    "new": newName,
                ])
            try db.execute(sql: """
                UPDATE shotAttribute SET text = :new WHERE key = :key AND text = :old
                """, arguments: [
                    "key": AttributeKey.tag,
                    "old": oldName,
                    "new": newName,
                ])
        }
    }

    func deleteTag(_ name: String) throws {
        try database.write { db in
            _ = try ShotAttribute
                .filter(Column("key") == AttributeKey.tag && Column("text") == name)
                .deleteAll(db)
        }
    }

    private static func fetchPayloads(
        _ db: Database,
        key: String
    ) throws -> [(shotID: Int64, payload: Data)] {
        try Row.fetchAll(db, sql: """
            SELECT shotID, payload FROM shotAttribute
            WHERE key = ? AND payload IS NOT NULL
            """, arguments: [key]).map {
                (shotID: $0["shotID"] as Int64, payload: $0["payload"] as Data)
            }
    }
}
