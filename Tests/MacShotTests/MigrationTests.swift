import XCTest
import GRDB
@testable import MacShot

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
}
