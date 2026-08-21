import XCTest
import GRDB
@testable import IndexApp

/// 迁移链的安全网：空库全量迁移、v3 → v4 重建表的数据保真。
final class MigrationTests: XCTestCase {

    /// 空库跑完整迁移链：所有表就位，migrator 报告全部完成。
    func testEmptyDatabaseRunsFullMigrationChain() throws {
        let dbQueue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(dbQueue)

        try dbQueue.read { db in
            XCTAssertTrue(try db.tableExists("shot"))
            XCTAssertTrue(try db.tableExists("revision"))
            XCTAssertTrue(try db.tableExists("shotAttribute"))
            XCTAssertTrue(try db.tableExists("shotFts"))
            XCTAssertTrue(try db.tableExists("attributeFts"))
            XCTAssertTrue(try db.tableExists("shotCollection"))
            XCTAssertTrue(try db.tableExists("shotCollectionItem"))
            XCTAssertTrue(try db.tableExists("shotAsset"))
            XCTAssertTrue(try db.columns(in: "shot").map(\.name).contains("customTitle"))
            XCTAssertEqual(
                try db.columns(in: "shotAsset").map(\.name),
                [
                    "id", "shotID", "kind", "path", "payload",
                    "schemaVersion", "createdAt", "updatedAt",
                ],
                "附件表保持精简；能从 kind 或数据推出的信息不要重复落列"
            )
            XCTAssertTrue(try AppDatabase.migrator.hasCompletedMigrations(db))
        }
    }

    /// 造 v3 形态数据（表级 UNIQUE(shotID, key) 还在）再跑 v4：
    /// - 属性行的 id 原样保留（attributeFts 的 rowid 就是它）；
    /// - (shotID, key) 解除唯一约束，同图可插多行同 key；
    /// - attributeFts 重建后旧数据、新数据都可查。
    func testV4RebuildPreservesRowsAndLiftsUniqueConstraint() throws {
        let dbQueue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(dbQueue, upTo: "v3_attributes")

        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO shot (sha256, capturedAt, pixelWidth, pixelHeight)
                VALUES ('deadbeef', ?, 10, 10)
                """, arguments: [Date()])
            // 两条不同 key 的属性，id 故意不连续。
            try db.execute(sql: """
                INSERT INTO shotAttribute (id, shotID, key, text, createdAt)
                VALUES (7, 1, 'category', 'invoice-2024', ?)
                """, arguments: [Date()])
            try db.execute(sql: """
                INSERT INTO shotAttribute (id, shotID, key, text, createdAt)
                VALUES (9, 1, 'tag', 'expense-report', ?)
                """, arguments: [Date()])
            // v3 的表级唯一约束确实还在：同 (shotID, key) 再插必须失败。
            XCTAssertThrowsError(try db.execute(sql: """
                INSERT INTO shotAttribute (shotID, key, text, createdAt)
                VALUES (1, 'tag', 'another', ?)
                """, arguments: [Date()]))
        }

        try AppDatabase.migrator.migrate(dbQueue)

        try dbQueue.write { db in
            // id 保留。
            let ids = try Int64.fetchAll(db, sql: "SELECT id FROM shotAttribute ORDER BY id")
            XCTAssertEqual(ids, [7, 9])

            // (shotID, key) 现在允许多行 —— 多值标签的前提。
            try db.execute(sql: """
                INSERT INTO shotAttribute (shotID, key, text, createdAt)
                VALUES (1, 'tag', 'travel-receipt', ?)
                """, arguments: [Date()])
            let tagCount = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM shotAttribute WHERE shotID = 1 AND key = 'tag'
                """)
            XCTAssertEqual(tagCount, 2)

            // attributeFts 重建：迁移前的旧行可查（trigram 子串匹配）。
            let oldHits = try Int64.fetchAll(db, sql: """
                SELECT shotAttribute.id FROM shotAttribute
                JOIN attributeFts ON attributeFts.rowid = shotAttribute.id
                WHERE attributeFts MATCH '"voice"'
                """)
            XCTAssertEqual(oldHits, [7])

            // 迁移后新插的行也被同步触发器索引。
            let newHits = try Int64.fetchAll(db, sql: """
                SELECT shotAttribute.shotID FROM shotAttribute
                JOIN attributeFts ON attributeFts.rowid = shotAttribute.id
                WHERE attributeFts MATCH '"travel"'
                """)
            XCTAssertEqual(newHits, [1])
        }
    }

    /// v6 将录像和分子来源从无类型属性迁入正式附件表；重复旧值只取最后一条，
    /// 迁移完成后旧属性删除，避免两个来源继续漂移。
    func testV6MigratesLegacyAssetsAndAddsQueryIndexes() throws {
        let dbQueue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(dbQueue, upTo: "v5_shot_collections")
        let molecule = Data("{\"schemaVersion\":1,\"format\":\"xyz\"}".utf8)

        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO shot (sha256, capturedAt, pixelWidth, pixelHeight)
                VALUES ('asset-shot', ?, 10, 10)
                """, arguments: [Date()])
            try db.execute(sql: """
                INSERT INTO shotAttribute (shotID, key, payload, createdAt)
                VALUES (1, ?, ?, ?), (1, ?, ?, ?), (1, ?, ?, ?)
                """, arguments: [
                    LegacyAttributeKey.recordingPath, Data("/tmp/old.mp4".utf8), Date(timeIntervalSince1970: 1),
                    LegacyAttributeKey.recordingPath, Data("/tmp/new.mp4".utf8), Date(timeIntervalSince1970: 2),
                    LegacyAttributeKey.moleculeXYZSource, molecule, Date(timeIntervalSince1970: 3),
                ])
        }

        try AppDatabase.migrator.migrate(dbQueue)

        try dbQueue.read { db in
            let assets = try ShotAsset.order(Column("kind")).fetchAll(db)
            XCTAssertEqual(assets.count, 2)
            XCTAssertEqual(
                assets.first(where: { $0.kind == ShotAssetKind.recording })?.path,
                "/tmp/new.mp4"
            )
            XCTAssertEqual(
                assets.first(where: { $0.kind == ShotAssetKind.moleculeXYZ })?.payload,
                molecule
            )
            let legacyCount = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM shotAttribute WHERE key IN (?, ?)
                """, arguments: [LegacyAttributeKey.recordingPath, LegacyAttributeKey.moleculeXYZSource])
            XCTAssertEqual(legacyCount, 0)

            let attributeIndexes = try db.indexes(on: "shotAttribute").map(\.name)
            XCTAssertTrue(attributeIndexes.contains("index_shotAttribute_on_key_shotID"))
            let collectionIndexes = try db.indexes(on: "shotCollectionItem").map(\.name)
            XCTAssertTrue(collectionIndexes.contains(
                "index_shotCollectionItem_on_collectionID_sortOrder_addedAt"
            ))
        }
    }

    /// v7 只给 Shot 增加用户显示名，并重建全文索引。旧截图必须原样保留，
    /// 迁移后写入的自定义名称也必须立即能被 FTS 搜到。
    func testV7AddsSearchableCustomTitleWithoutChangingExistingShot() throws {
        let dbQueue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(dbQueue, upTo: "v6_shot_assets")

        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO shot (
                    sha256, capturedAt, pixelWidth, pixelHeight, windowTitle
                ) VALUES ('stable-original-hash', ?, 320, 200, '旧窗口标题')
                """, arguments: [Date(timeIntervalSince1970: 123)])
        }

        try AppDatabase.migrator.migrate(dbQueue)

        try dbQueue.write { db in
            let migrated = try XCTUnwrap(Shot.fetchOne(db, key: 1))
            XCTAssertEqual(migrated.sha256, "stable-original-hash")
            XCTAssertEqual(migrated.windowTitle, "旧窗口标题")
            XCTAssertNil(migrated.customTitle)

            try db.execute(
                sql: "UPDATE shot SET customTitle = ? WHERE id = 1",
                arguments: ["MR-TADF molecule notes"]
            )
            let hits = try Int64.fetchAll(db, sql: """
                SELECT shot.id FROM shot
                JOIN shotFts ON shotFts.rowid = shot.id
                WHERE shotFts MATCH '"molecule"'
                """)
            XCTAssertEqual(hits, [1])
        }
    }
}
