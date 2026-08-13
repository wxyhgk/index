import Foundation
import GRDB

/// 图库当前页的卡片派生信息。一次后台数据库快照返回，避免 UI 串行读取多个仓库。
struct ShotPageMetadata: Equatable {
    let categoriesByShot: [Int64: String]
    let annotatedShotIDs: Set<Int64>
    let recordingPathsByShot: [Int64: String]
    let collectionSummaries: [ShotCollectionSummary]
    let collectionIDsByShot: [Int64: Set<Int64>]

    static let empty = ShotPageMetadata(
        categoriesByShot: [:],
        annotatedShotIDs: [],
        recordingPathsByShot: [:],
        collectionSummaries: [],
        collectionIDsByShot: [:]
    )

    /// 分页追加时只读取新页，再和已发布的前缀合并。专题摘要始终取最新查询值，
    /// 其余字典 / 集合按 shotID 合并；同一 shot 的新值覆盖旧值。
    func merging(_ newer: ShotPageMetadata) -> ShotPageMetadata {
        var categories = categoriesByShot
        categories.merge(newer.categoriesByShot) { _, new in new }

        var recordingPaths = recordingPathsByShot
        recordingPaths.merge(newer.recordingPathsByShot) { _, new in new }

        var memberships = collectionIDsByShot
        memberships.merge(newer.collectionIDsByShot) { _, new in new }

        return ShotPageMetadata(
            categoriesByShot: categories,
            annotatedShotIDs: annotatedShotIDs.union(newer.annotatedShotIDs),
            recordingPathsByShot: recordingPaths,
            collectionSummaries: newer.collectionSummaries,
            collectionIDsByShot: memberships
        )
    }
}

struct ShotPageMetadataRepository {
    private let database: any DatabaseWriter

    init(database: any DatabaseWriter) {
        self.database = database
    }

    func fetchInBackground(shotIDs rawShotIDs: [Int64]) async throws -> ShotPageMetadata {
        let shotIDs = Array(Set(rawShotIDs))
        return try await database.read { db in
            // 网格右键菜单只需要专题名称与计数，不读取首页预览图。
            let collections = try ShotCollectionRepository.fetchSummaries(db, previewLimit: 0)
            guard !shotIDs.isEmpty else {
                return ShotPageMetadata(
                    categoriesByShot: [:],
                    annotatedShotIDs: [],
                    recordingPathsByShot: [:],
                    collectionSummaries: collections,
                    collectionIDsByShot: [:]
                )
            }

            // SQLite 的变量上限会随构建配置变化；每块 500 个 ID，并给带 kind/key 的
            // 查询留出额外参数。整个循环仍在同一个 read transaction 内，语义上是一张快照。
            var categories: [Int64: String] = [:]
            var annotated: Set<Int64> = []
            var recordingPaths: [Int64: String] = [:]
            var memberships: [Int64: Set<Int64>] = [:]

            for start in stride(from: 0, to: shotIDs.count, by: 500) {
                let end = min(start + 500, shotIDs.count)
                let chunk = Array(shotIDs[start..<end])
                let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
                let categoryRows = try Row.fetchAll(db, sql: """
                    SELECT shotID, text FROM shotAttribute
                    WHERE key = ? AND shotID IN (\(placeholders)) AND text IS NOT NULL
                    ORDER BY id ASC
                    """, arguments: StatementArguments([AttributeKey.category] + chunk))
                for row in categoryRows {
                    let shotID: Int64 = row["shotID"]
                    let text: String = row["text"]
                    categories[shotID] = text
                }

                annotated.formUnion(try Int64.fetchAll(db, sql: """
                    SELECT shotID FROM revision
                    WHERE shotID IN (\(placeholders))
                    GROUP BY shotID HAVING COUNT(*) > 1
                    """, arguments: StatementArguments(chunk)))

                let assetRows = try Row.fetchAll(db, sql: """
                    SELECT shotID, path FROM shotAsset
                    WHERE kind = ? AND shotID IN (\(placeholders)) AND path IS NOT NULL
                    """, arguments: StatementArguments([ShotAssetKind.recording] + chunk))
                for row in assetRows {
                    let shotID: Int64 = row["shotID"]
                    let path: String = row["path"]
                    recordingPaths[shotID] = path
                }

                let membershipRows = try Row.fetchAll(db, sql: """
                    SELECT shotID, collectionID FROM shotCollectionItem
                    WHERE shotID IN (\(placeholders))
                    """, arguments: StatementArguments(chunk))
                for row in membershipRows {
                    let shotID: Int64 = row["shotID"]
                    let collectionID: Int64 = row["collectionID"]
                    memberships[shotID, default: []].insert(collectionID)
                }
            }

            return ShotPageMetadata(
                categoriesByShot: categories,
                annotatedShotIDs: annotated,
                recordingPathsByShot: recordingPaths,
                collectionSummaries: collections,
                collectionIDsByShot: memberships
            )
        }
    }
}
