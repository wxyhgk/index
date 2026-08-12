import Foundation
import GRDB

/// 专题收藏集、成员关系与首页摘要的数据库入口。
///
/// 该类型不持有当前筛选或 UI 刷新状态。名称的空白清洗属于 `ShotStore` 的
/// 输入边界；唯一约束、成员幂等和查询顺序属于这里的持久化边界。
struct ShotCollectionRepository {
    private let database: any DatabaseWriter

    init(database: any DatabaseWriter) {
        self.database = database
    }

    func summaries(previewLimit: Int = 3) throws -> [ShotCollectionSummary] {
        try database.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT c.id, c.name, c.note, c.updatedAt, COUNT(i.shotID) AS itemCount
                FROM shotCollection c
                LEFT JOIN shotCollectionItem i ON i.collectionID = c.id
                GROUP BY c.id
                ORDER BY c.sortOrder ASC, c.updatedAt DESC, c.id DESC
                """)
            return try rows.map { row in
                let id: Int64 = row["id"]
                let previews = try Shot.fetchAll(db, sql: """
                    SELECT shot.* FROM shotCollectionItem item
                    JOIN shot ON shot.id = item.shotID
                    WHERE item.collectionID = ?
                    ORDER BY item.sortOrder ASC, item.addedAt DESC, shot.id DESC
                    LIMIT ?
                    """, arguments: [id, previewLimit])
                return ShotCollectionSummary(
                    id: id,
                    name: row["name"],
                    note: row["note"],
                    itemCount: row["itemCount"],
                    updatedAt: row["updatedAt"],
                    previews: previews
                )
            }
        }
    }

    func count() throws -> Int {
        try database.read { db in
            try ShotCollection.fetchCount(db)
        }
    }

    /// `name` 与 `note` 已由调用边界完成清洗。
    func create(name: String, note: String) throws -> ShotCollection {
        let now = Date()
        var collection = ShotCollection(
            id: nil,
            name: name,
            note: note,
            coverShotID: nil,
            createdAt: now,
            updatedAt: now,
            sortOrder: 0
        )
        do {
            try database.write { db in
                try collection.insert(db)
            }
        } catch let error as DatabaseError
            where error.extendedResultCode == .SQLITE_CONSTRAINT_UNIQUE {
            throw ShotCollectionError.duplicateName
        }
        return collection
    }

    /// `name` 已由调用边界完成清洗。
    func rename(id: Int64, to name: String) throws {
        do {
            let changed = try database.write { db in
                try db.execute(
                    sql: "UPDATE shotCollection SET name = ?, updatedAt = ? WHERE id = ?",
                    arguments: [name, Date(), id]
                )
                return db.changesCount
            }
            guard changed > 0 else { throw ShotCollectionError.collectionNotFound }
        } catch let error as DatabaseError
            where error.extendedResultCode == .SQLITE_CONSTRAINT_UNIQUE {
            throw ShotCollectionError.duplicateName
        }
    }

    @discardableResult
    func delete(id: Int64) throws -> Bool {
        try database.write { db in
            try ShotCollection.deleteOne(db, key: id)
        }
    }

    /// 幂等加入：重复 ID 与数据库中已有的成员都不会生成重复行。
    func add(shotIDs: [Int64], to collectionID: Int64) throws {
        let ids = Array(Set(shotIDs))
        guard !ids.isEmpty else { return }
        try database.write { db in
            guard try ShotCollection.fetchOne(db, key: collectionID) != nil else {
                throw ShotCollectionError.collectionNotFound
            }
            let now = Date()
            for shotID in ids {
                try db.execute(sql: """
                    INSERT OR IGNORE INTO shotCollectionItem
                        (collectionID, shotID, addedAt, sortOrder)
                    VALUES (?, ?, ?, 0)
                    """, arguments: [collectionID, shotID, now])
            }
            try db.execute(
                sql: "UPDATE shotCollection SET updatedAt = ? WHERE id = ?",
                arguments: [now, collectionID]
            )
        }
    }

    func remove(shotIDs: [Int64], from collectionID: Int64) throws {
        let ids = Array(Set(shotIDs))
        guard !ids.isEmpty else { return }
        try database.write { db in
            try db.execute(sql: """
                DELETE FROM shotCollectionItem
                WHERE collectionID = ? AND shotID IN (\(ids.map { _ in "?" }.joined(separator: ",")))
                """, arguments: StatementArguments([collectionID] + ids))
            try db.execute(
                sql: "UPDATE shotCollection SET updatedAt = ? WHERE id = ?",
                arguments: [Date(), collectionID]
            )
        }
    }

    func memberships(shotIDs: [Int64]) throws -> [Int64: Set<Int64>] {
        let ids = Array(Set(shotIDs))
        guard !ids.isEmpty else { return [:] }
        return try database.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT shotID, collectionID FROM shotCollectionItem
                WHERE shotID IN (\(ids.map { _ in "?" }.joined(separator: ",")))
                """, arguments: StatementArguments(ids))
            return rows.reduce(into: [Int64: Set<Int64>]()) { result, row in
                let shotID: Int64 = row["shotID"]
                let collectionID: Int64 = row["collectionID"]
                result[shotID, default: []].insert(collectionID)
            }
        }
    }
}
