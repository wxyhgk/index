import Foundation
import GRDB

/// Shot 初始版本与 append-only 修订链的数据库入口。
///
/// 每张 Shot 必须和一条“原始”修订在同一事务创建；追加时也必须在同一事务
/// 读取末端并插入新节点，避免并发编辑产生意外分叉。缩略图渲染等文件副作用
/// 不属于本仓储，由事务成功后的 `ShotStore` 负责。
struct ShotRevisionRepository {
    private let database: any DatabaseWriter

    init(database: any DatabaseWriter) {
        self.database = database
    }

    func insertShotWithInitialRevision(
        _ newShot: Shot,
        note: String
    ) throws -> Shot {
        var shot = newShot
        try database.write { db in
            try shot.insert(db)
            guard let shotID = shot.id else {
                throw RepositoryError.missingShotID
            }
            var initial = Revision.make(
                shotID: shotID,
                parentID: nil,
                layers: [],
                note: note
            )
            try initial.insert(db)
        }
        return shot
    }

    func revisions(shotID: Int64) throws -> [Revision] {
        try database.read { db in
            try Revision
                .filter(Revision.Columns.shotID == shotID)
                .order(Revision.Columns.createdAt.asc, Column("id").asc)
                .fetchAll(db)
        }
    }

    func latestRevision(shotID: Int64) throws -> Revision? {
        try database.read { db in
            try Revision
                .filter(Revision.Columns.shotID == shotID)
                .order(Revision.Columns.createdAt.desc, Column("id").desc)
                .fetchOne(db)
        }
    }

    func append(
        shotID: Int64,
        layers: [Layer],
        note: String?
    ) throws -> Revision {
        try database.write { db in
            let parent = try Revision
                .filter(Revision.Columns.shotID == shotID)
                .order(Column("id").desc)
                .fetchOne(db)

            var revision = Revision.make(
                shotID: shotID,
                parentID: parent?.id,
                layers: layers,
                note: note
            )
            try revision.insert(db)
            return revision
        }
    }

    func annotatedCount() throws -> Int {
        try database.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM (
                    SELECT shotID FROM revision GROUP BY shotID HAVING COUNT(*) > 1
                )
                """) ?? 0
        }
    }

    func annotatedShotIDs(among shotIDs: [Int64]) throws -> Set<Int64> {
        guard !shotIDs.isEmpty else { return [] }
        return try database.read { db in
            Set(try Int64.fetchAll(db, sql: """
                SELECT shotID FROM revision
                WHERE shotID IN (\(shotIDs.map { _ in "?" }.joined(separator: ",")))
                GROUP BY shotID
                HAVING COUNT(*) > 1
                """, arguments: StatementArguments(shotIDs)))
        }
    }

    enum RepositoryError: Error {
        case missingShotID
    }
}
