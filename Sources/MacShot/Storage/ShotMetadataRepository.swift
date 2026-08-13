import Foundation
import GRDB

/// 与文件目录无关的数据库快照；`ShotStore` 再把内容哈希映射到真实原图 URL。
struct ShotOutputRecord: Equatable {
    let shot: Shot
    let layers: Layers<ImageSpace>
}

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
        try database.read { db in
            try Self.fetchShots(db, ids: ids)
        }
    }

    /// 大选中集合的后台解析入口。SQLite 的绑定参数数目有上限，所以按固定大小分块，
    /// 最后再按调用方给出的 ID 顺序重排；`IN (...)` 自身不保证返回顺序。
    func shotsInBackground(ids: [Int64]) async throws -> [Shot] {
        try await database.read { db in
            try Self.fetchShots(db, ids: ids)
        }
    }

    /// 批量输出材料必须在一次 read snapshot 中同时取得 Shot 和最新修订。
    /// 每 500 个 ID 一组，既避开 SQLite 绑定参数上限，也不让一万张全选生成巨型 SQL。
    func outputRecordsInBackground(ids: [Int64]) async throws -> [ShotOutputRecord] {
        try await database.read { db in
            let shots = try Self.fetchShots(db, ids: ids)
            let shotIDs = shots.compactMap(\.id)
            guard !shotIDs.isEmpty else { return [] }

            var revisionsByShot: [Int64: Revision] = [:]
            revisionsByShot.reserveCapacity(shotIDs.count)
            for start in stride(from: 0, to: shotIDs.count, by: 500) {
                let chunk = Array(shotIDs[start..<min(start + 500, shotIDs.count)])
                let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
                let revisions = try Revision.fetchAll(db, sql: """
                    SELECT * FROM revision
                    WHERE id IN (
                        SELECT id FROM (
                            SELECT id,
                                   ROW_NUMBER() OVER (
                                       PARTITION BY shotID
                                       ORDER BY createdAt DESC, id DESC
                                   ) AS latestRank
                            FROM revision
                            WHERE shotID IN (\(placeholders))
                        )
                        WHERE latestRank = 1
                    )
                    """, arguments: StatementArguments(chunk))
                for revision in revisions {
                    revisionsByShot[revision.shotID] = revision
                }
            }

            return shots.map { shot in
                let layers = shot.id.flatMap { revisionsByShot[$0] }?.imageLayers ?? Layers()
                return ShotOutputRecord(shot: shot, layers: layers)
            }
        }
    }

    private static func fetchShots(_ db: Database, ids: [Int64]) throws -> [Shot] {
        var seen = Set<Int64>()
        let orderedIDs = ids.filter { seen.insert($0).inserted }
        guard !orderedIDs.isEmpty else { return [] }

        var byID: [Int64: Shot] = [:]
        byID.reserveCapacity(orderedIDs.count)
        for start in stride(from: 0, to: orderedIDs.count, by: 500) {
            let chunk = Array(orderedIDs[start..<min(start + 500, orderedIDs.count)])
            let shots = try Shot.filter(chunk.contains(Column("id"))).fetchAll(db)
            for shot in shots {
                if let id = shot.id { byID[id] = shot }
            }
        }
        return orderedIDs.compactMap { byID[$0] }
    }

    /// 按 ID 删除，供跨分页批量删除使用。目标 Shot 不需要先全部解码到主线程；
    /// 候选内容哈希和引用计数都在同一事务内计算。
    func delete(ids: [Int64]) throws -> Set<String> {
        var seen = Set<Int64>()
        let uniqueIDs = ids.filter { seen.insert($0).inserted }
        guard !uniqueIDs.isEmpty else { return [] }

        return try database.write { db in
            var candidateHashes = Set<String>()
            for start in stride(from: 0, to: uniqueIDs.count, by: 500) {
                let chunk = Array(uniqueIDs[start..<min(start + 500, uniqueIDs.count)])
                let hashes = try String.fetchAll(db, sql: """
                    SELECT DISTINCT sha256 FROM shot
                    WHERE id IN (\(chunk.map { _ in "?" }.joined(separator: ",")))
                    """, arguments: StatementArguments(chunk))
                candidateHashes.formUnion(hashes)
                try Shot.filter(chunk.contains(Column("id"))).deleteAll(db)
            }

            var stillReferenced = Set<String>()
            let hashes = Array(candidateHashes)
            for start in stride(from: 0, to: hashes.count, by: 500) {
                let chunk = Array(hashes[start..<min(start + 500, hashes.count)])
                stillReferenced.formUnion(try String.fetchAll(db, sql: """
                    SELECT DISTINCT sha256 FROM shot
                    WHERE sha256 IN (\(chunk.map { _ in "?" }.joined(separator: ",")))
                    """, arguments: StatementArguments(chunk)))
            }
            return candidateHashes.subtracting(stillReferenced)
        }
    }

    func updateCustomTitle(_ title: String?, shotID: Int64) throws {
        try database.write { db in
            try db.execute(
                sql: "UPDATE shot SET customTitle = ? WHERE id = ?",
                arguments: [title, shotID]
            )
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
