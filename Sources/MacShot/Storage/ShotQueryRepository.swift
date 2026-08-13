import Foundation
import GRDB

/// 图库 Shot 列表、筛选、分页和清理候选的查询仓库。
///
/// 不持有搜索框、分页进度或发布状态；相同查询体同时服务同步首屏、后台刷新、
/// 下一页、全选和语义搜索候选，避免各入口的筛选语义慢慢漂移。
struct ShotQueryRepository {
    /// 一次观察回调里同时取回当前页与收藏集合，保证 UI 永远看到同一个数据库快照。
    struct LibrarySnapshot: Equatable {
        let shots: [Shot]
        let favoriteIDs: Set<Int64>
    }

    struct PageCursor: Equatable, Sendable {
        let capturedAt: Date
        let id: Int64
    }

    private let database: any DatabaseWriter

    init(database: any DatabaseWriter) {
        self.database = database
    }

    func shots(
        query: String,
        filter: ShotFilter,
        after cursor: PageCursor? = nil,
        limit: Int
    ) throws -> [Shot] {
        try database.read { db in
            try Self.fetchRows(
                db,
                query: query,
                filter: filter,
                after: cursor,
                limit: limit
            )
        }
    }

    func shotsInBackground(
        query: String,
        filter: ShotFilter,
        after cursor: PageCursor? = nil,
        limit: Int
    ) async throws -> [Shot] {
        try await database.read { db in
            try Self.fetchRows(
                db,
                query: query,
                filter: filter,
                after: cursor,
                limit: limit
            )
        }
    }

    /// 与列表查询完全相同的搜索/筛选语义，但只解码主键。
    func matchingIDsInBackground(query: String, filter: ShotFilter) async throws -> [Int64] {
        try await database.read { db in
            let statement = Self.makeListStatement(
                selection: "shot.id",
                query: query,
                filter: filter,
                after: nil,
                limit: Int.max
            )
            return try Int64.fetchAll(db, sql: statement.sql, arguments: statement.arguments)
        }
    }

    /// 观察图库库存，并把数据库提交自动转换成完整的列表快照。
    ///
    /// 这里故意使用显式 region，而不是只依赖查询自动推导：应用/收藏集首页还要在
    /// 集合改名、附件挂载等「当前 Shot 行本身没变」的提交后刷新聚合数据。修订表只在
    /// `.annotated` 筛选下加入观察，避免编辑器自动保存每个修订都重查整个图库。
    @MainActor
    func observeLibrary(
        query: String,
        filter: ShotFilter,
        limit: Int,
        immediately: Bool,
        onError: @escaping @Sendable @MainActor (Error) -> Void,
        onChange: @escaping @Sendable @MainActor (LibrarySnapshot) -> Void
    ) -> AnyDatabaseCancellable {
        var regions: [any DatabaseRegionConvertible] = [
            Table("shot"),
            Table("shotAttribute"),
            Table("shotAsset"),
            Table("shotCollection"),
            Table("shotCollectionItem"),
        ]
        if filter == .annotated {
            regions.append(Table("revision"))
        }

        let observation = ValueObservation.tracking(regions: regions) { db in
            let shots = try Self.fetchRows(
                db,
                query: query,
                filter: filter,
                after: nil,
                limit: limit
            )
            let favoriteIDs = Set(try Int64.fetchAll(db, sql: """
                SELECT shotID FROM shotAttribute WHERE key = ?
                """, arguments: [AttributeKey.favorite]))
            return LibrarySnapshot(shots: shots, favoriteIDs: favoriteIDs)
        }

        if immediately {
            return observation.start(
                in: database,
                scheduling: .immediate,
                onError: onError,
                onChange: onChange
            )
        }
        return observation.start(
            in: database,
            scheduling: .mainActor,
            onError: onError,
            onChange: onChange
        )
    }

    func cleanupCandidates(olderThan cutoff: Date, limit: Int) throws -> [Shot] {
        try database.read { db in
            try Shot.fetchAll(db, sql: """
                SELECT shot.* FROM shot
                LEFT JOIN revision ON revision.shotID = shot.id
                WHERE shot.capturedAt < :cutoff
                  AND shot.id NOT IN (
                      SELECT shotID FROM shotAttribute WHERE key = :favoriteKey
                  )
                  AND NOT EXISTS (
                      SELECT 1 FROM shotAttribute
                      WHERE shotID = shot.id AND key = :tagKey
                  )
                  AND NOT EXISTS (
                      SELECT 1 FROM shotCollectionItem
                      WHERE shotID = shot.id
                  )
                  AND NOT EXISTS (
                      SELECT 1 FROM shotAsset
                      WHERE shotID = shot.id
                  )
                GROUP BY shot.id
                HAVING COUNT(revision.id) <= 1
                ORDER BY shot.capturedAt ASC
                LIMIT :limit
                """, arguments: [
                    "cutoff": cutoff,
                    "favoriteKey": AttributeKey.favorite,
                    "tagKey": AttributeKey.tag,
                    "limit": limit,
                ])
        }
    }

    func untaggedCount() throws -> Int {
        try database.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM shot
                WHERE NOT EXISTS (
                    SELECT 1 FROM shotAttribute
                    WHERE shotAttribute.shotID = shot.id AND shotAttribute.key = ?
                )
                """, arguments: [AttributeKey.tag]) ?? 0
        }
    }

    private static func fetchRows(
        _ db: Database,
        query: String,
        filter: ShotFilter,
        after cursor: PageCursor?,
        limit: Int
    ) throws -> [Shot] {
        let statement = makeListStatement(
            selection: "shot.*",
            query: query,
            filter: filter,
            after: cursor,
            limit: limit
        )
        return try Shot.fetchAll(db, sql: statement.sql, arguments: statement.arguments)
    }

    private struct ListStatement {
        let sql: String
        let arguments: StatementArguments
    }

    /// 列表与 ID-only 查询共用这一份 SQL 组装，避免全选的筛选语义慢慢漂移。
    private static func makeListStatement(
        selection: String,
        query: String,
        filter: ShotFilter,
        after cursor: PageCursor?,
        limit: Int
    ) -> ListStatement {
        let filterClause: String
        var arguments: [String: (any DatabaseValueConvertible)?] = [:]

        var cursorClause = ""
        if let cursor {
            cursorClause = """
                AND (shot.capturedAt, shot.id) < (:cursorAt, :cursorID)
                """
            arguments["cursorAt"] = cursor.capturedAt
            arguments["cursorID"] = cursor.id
        }

        switch filter {
        case .all:
            filterClause = ""
        case .favorites:
            filterClause = """
                AND shot.id IN (
                    SELECT shotID FROM shotAttribute WHERE key = :favoriteKey
                )
                """
            arguments["favoriteKey"] = AttributeKey.favorite
        case .untagged:
            filterClause = """
                AND NOT EXISTS (
                    SELECT 1 FROM shotAttribute
                    WHERE shotID = shot.id AND key = :tagKey
                )
                """
            arguments["tagKey"] = AttributeKey.tag
        case .annotated:
            filterClause = """
                AND shot.id IN (
                    SELECT shotID FROM revision GROUP BY shotID HAVING COUNT(*) > 1
                )
                """
        case .recordings:
            filterClause = """
                AND EXISTS (
                    SELECT 1 FROM shotAsset
                    WHERE shotID = shot.id AND kind = :recordingKind
                )
                """
            arguments["recordingKind"] = ShotAssetKind.recording
        case .category(let name):
            filterClause = """
                AND shot.id IN (
                    SELECT shotID FROM shotAttribute
                    WHERE key = :categoryKey AND text = :filterValue
                )
                """
            arguments["categoryKey"] = AttributeKey.category
            arguments["filterValue"] = name
        case .tag(let name):
            filterClause = """
                AND EXISTS (
                    SELECT 1 FROM shotAttribute
                    WHERE shotID = shot.id AND key = :tagKey AND text = :filterValue
                )
                """
            arguments["tagKey"] = AttributeKey.tag
            arguments["filterValue"] = name
        case .app(let identity):
            if let bundleID = identity.bundleID {
                filterClause = "AND shot.appBundleID = :filterBundleID"
                arguments["filterBundleID"] = bundleID
            } else {
                filterClause = """
                    AND (shot.appBundleID IS NULL OR TRIM(shot.appBundleID) = '')
                    AND shot.appName = :filterValue
                    """
                arguments["filterValue"] = identity.name
            }
        case .collection(let collectionID):
            filterClause = """
                AND EXISTS (
                    SELECT 1 FROM shotCollectionItem
                    WHERE shotID = shot.id AND collectionID = :collectionID
                )
                """
            arguments["collectionID"] = collectionID
        }

        if query.isEmpty {
            return ListStatement(sql: """
                SELECT \(selection) FROM shot
                WHERE 1 = 1 \(filterClause)
                \(cursorClause)
                ORDER BY shot.capturedAt DESC, shot.id DESC
                LIMIT \(limit)
                """, arguments: StatementArguments(arguments))
        }

        // trigram 不索引少于 3 个字符的词；短查询保持 LIKE 子串语义。
        if query.count < 3 {
            let escaped = query
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "%", with: "\\%")
                .replacingOccurrences(of: "_", with: "\\_")
            arguments["like"] = "%\(escaped)%"
            return ListStatement(sql: """
                SELECT \(selection) FROM shot
                WHERE (
                    shot.customTitle LIKE :like ESCAPE '\\'
                    OR shot.appName LIKE :like ESCAPE '\\'
                    OR shot.windowTitle LIKE :like ESCAPE '\\'
                    OR shot.sourceURL LIKE :like ESCAPE '\\'
                    OR shot.ocrText LIKE :like ESCAPE '\\'
                    OR shot.id IN (
                        SELECT shotID FROM shotAttribute
                        WHERE text LIKE :like ESCAPE '\\'
                    )
                ) \(filterClause)
                \(cursorClause)
                ORDER BY shot.capturedAt DESC, shot.id DESC
                LIMIT \(limit)
                """, arguments: StatementArguments(arguments))
        }

        let escaped = query.replacingOccurrences(of: "\"", with: "\"\"")
        arguments["pattern"] = "\"\(escaped)\""
        return ListStatement(sql: """
            SELECT \(selection) FROM shot
            WHERE shot.id IN (
                SELECT shotFts.rowid FROM shotFts WHERE shotFts MATCH :pattern
                UNION
                SELECT shotAttribute.shotID FROM shotAttribute
                JOIN attributeFts ON attributeFts.rowid = shotAttribute.id
                WHERE attributeFts MATCH :pattern
            ) \(filterClause)
            \(cursorClause)
            ORDER BY shot.capturedAt DESC, shot.id DESC
            LIMIT \(limit)
            """, arguments: StatementArguments(arguments))
    }
}
