import Foundation
import GRDB

/// `shotAsset` 附件自身 CRUD 与直接查询的 SQL 入口。
///
/// 该类型不属于 MainActor，也不持有 UI 状态。`ShotStore` 只负责把领域对象编解码为
/// `path` / `payload`，数据库细节留在这里，后续可在不改调用方协议的前提下切换为
/// 后台 async 读取或拆成独立数据库服务。图库筛选、自动清理这类跨实体查询仍由
/// Shot 查询层负责，避免本仓库反向认识整个图库。
struct ShotAssetRepository {
    private let database: any DatabaseWriter

    init(database: any DatabaseWriter) {
        self.database = database
    }

    func upsert(
        shotID: Int64,
        kind: String,
        path: String?,
        payload: Data?,
        schemaVersion: Int
    ) throws {
        let now = Date()
        try database.write { db in
            try db.execute(sql: """
                INSERT INTO shotAsset (
                    shotID, kind, path, payload, schemaVersion, createdAt, updatedAt
                ) VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(shotID, kind) DO UPDATE SET
                    path = excluded.path,
                    payload = excluded.payload,
                    schemaVersion = excluded.schemaVersion,
                    updatedAt = excluded.updatedAt
                """, arguments: [
                    shotID, kind, path, payload, schemaVersion, now, now,
                ])
        }
    }

    func payload(shotID: Int64, kind: String) throws -> Data? {
        try database.read { db in
            try Data.fetchOne(db, sql: """
                SELECT payload FROM shotAsset
                WHERE shotID = ? AND kind = ? AND payload IS NOT NULL LIMIT 1
                """, arguments: [shotID, kind])
        }
    }

    func paths(kind: String, shotIDs: [Int64]) throws -> [Int64: String] {
        guard !shotIDs.isEmpty else { return [:] }
        let rows = try database.read { db in
            try ShotAsset
                .filter(
                    Column("kind") == kind
                        && shotIDs.contains(Column("shotID"))
                )
                .fetchAll(db)
        }
        return rows.reduce(into: [:]) { result, asset in
            if let path = asset.path { result[asset.shotID] = path }
        }
    }

    func count(kind: String) throws -> Int {
        try database.read { db in
            try ShotAsset
                .filter(Column("kind") == kind)
                .fetchCount(db)
        }
    }
}
