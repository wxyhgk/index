import Foundation
import GRDB

/// Shot 本体的直接查询、来源聚合与删除事务入口。
///
/// 删除只返回已经没有数据库引用的内容哈希；原图和缩略图文件必须等事务提交后，
/// 再由 `ShotStore` 删除。来源 URL 查询只做 SQL 前缀缩候选，归一化精确判定属于领域层。
struct ShotMetadataRepository {
    private let database: any DatabaseWriter

    init(database: any DatabaseWriter) {
        self.database = database
    }

    func count() throws -> Int {
        try database.read { db in
            try Shot.fetchCount(db)
        }
    }

    func recent(limit: Int) throws -> [Shot] {
        try database.read { db in
            try Shot.fetchAll(db, sql: """
                SELECT * FROM shot ORDER BY capturedAt DESC LIMIT ?
                """, arguments: [limit])
        }
    }

    func exists(id: Int64) throws -> Bool {
        try database.read { db in
            try Shot.filter(key: id).fetchCount(db) > 0
        }
    }

    func shots(ids: [Int64]) throws -> [Shot] {
        guard !ids.isEmpty else { return [] }
        return try database.read { db in
            try Shot.filter(ids.contains(Column("id"))).fetchAll(db)
        }
    }

    /// 删除数据库记录，并在同一事务内计算不再被任何 Shot 引用的内容哈希。
    func delete(_ shots: [Shot]) throws -> Set<String> {
        let ids = shots.compactMap(\.id)
        guard !ids.isEmpty else { return [] }
        let candidateHashes = Set(shots.filter { $0.id != nil }.map(\.sha256))

        return try database.write { db in
            try Shot.filter(ids.contains(Column("id"))).deleteAll(db)
            let stillReferenced = try Shot
                .select(Column("sha256"), as: String.self)
                .filter(candidateHashes.contains(Column("sha256")))
                .distinct()
                .fetchAll(db)
            return candidateHashes.subtracting(stillReferenced)
        }
    }

    /// 应用首页的完整聚合：稳定身份、数量、最近捕获时间和最新三张预览。
    func capturedApps(previewLimit: Int = 3) throws -> [CapturedAppSummary] {
        try database.read { db in
            let identitySQL = """
                CASE
                    WHEN appBundleID IS NOT NULL AND TRIM(appBundleID) != ''
                    THEN 'bundle:' || TRIM(appBundleID)
                    ELSE 'name:' || appName
                END
                """

            let rows = try Row.fetchAll(db, sql: """
                WITH ranked AS (
                    SELECT shot.*,
                           \(identitySQL) AS appIdentity,
                           ROW_NUMBER() OVER (
                               PARTITION BY \(identitySQL)
                               ORDER BY capturedAt DESC, id DESC
                           ) AS appRank,
                           COUNT(*) OVER (PARTITION BY \(identitySQL)) AS captureCount,
                           MAX(capturedAt) OVER (PARTITION BY \(identitySQL)) AS lastCapturedAt
                    FROM shot
                    WHERE appName IS NOT NULL AND TRIM(appName) != ''
                )
                SELECT * FROM ranked
                WHERE appRank <= ?
                ORDER BY captureCount DESC, appIdentity ASC, appRank ASC
                """, arguments: [previewLimit])

            struct Builder {
                let identity: CapturedAppIdentity
                let captureCount: Int
                let lastCapturedAt: Date
                var previews: [Shot]
            }

            var orderedIDs: [String] = []
            var builders: [String: Builder] = [:]
            for row in rows {
                let stableID = row["appIdentity"] as String
                if builders[stableID] == nil {
                    orderedIDs.append(stableID)
                    builders[stableID] = Builder(
                        identity: CapturedAppIdentity(
                            name: row["appName"] as String,
                            bundleID: row["appBundleID"] as String?
                        ),
                        captureCount: row["captureCount"] as Int,
                        lastCapturedAt: row["lastCapturedAt"] as Date,
                        previews: []
                    )
                }
                builders[stableID]?.previews.append(try Shot(row: row))
            }

            return orderedIDs.compactMap { stableID in
                guard let builder = builders[stableID] else { return nil }
                return CapturedAppSummary(
                    identity: builder.identity,
                    captureCount: builder.captureCount,
                    lastCapturedAt: builder.lastCapturedAt,
                    previews: builder.previews
                )
            }
        }
    }

    func relatedBySourcePrefix(_ prefix: String) throws -> [Shot] {
        let escaped = prefix
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        return try database.read { db in
            try Shot
                .filter(Column("sourceURL").like("\(escaped)%", escape: "\\"))
                .order(Column("capturedAt").asc, Column("id").asc)
                .fetchAll(db)
        }
    }

    func related(bundleID: String, windowTitle: String?) throws -> [Shot] {
        try database.read { db in
            let predicate: SQLSpecificExpressible
            if let windowTitle {
                predicate = Column("appBundleID") == bundleID
                    && Column("windowTitle") == windowTitle
            } else {
                predicate = Column("appBundleID") == bundleID
            }
            return try Shot
                .filter(predicate)
                .order(Column("capturedAt").asc, Column("id").asc)
                .fetchAll(db)
        }
    }
}
