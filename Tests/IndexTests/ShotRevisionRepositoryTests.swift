import Foundation
import GRDB
import XCTest
@testable import IndexApp

final class ShotRevisionRepositoryTests: XCTestCase {
    private func makeDatabase() throws -> DatabaseQueue {
        let database = try DatabaseQueue()
        try AppDatabase.migrator.migrate(database)
        return database
    }

    private func makeShot(_ suffix: String) -> Shot {
        Shot(
            id: nil,
            sha256: "revision-repository-\(suffix)",
            capturedAt: Date(),
            pixelWidth: 10,
            pixelHeight: 10,
            scale: 2,
            appName: nil,
            appBundleID: nil,
            appVersion: nil,
            appBuild: nil,
            windowTitle: nil,
            sourceURL: nil,
            displayID: nil,
            displayName: nil,
            regionX: 0,
            regionY: 0,
            regionW: 10,
            regionH: 10,
            ocrText: nil
        )
    }

    func testShotAndInitialRevisionCommitAtomically() throws {
        let database = try makeDatabase()
        let repository = ShotRevisionRepository(database: database)
        try database.write { db in
            try db.execute(sql: """
                CREATE TRIGGER reject_initial_revision
                BEFORE INSERT ON revision
                WHEN NEW.note = '拒绝'
                BEGIN
                    SELECT RAISE(ABORT, 'reject initial revision');
                END
                """)
        }

        XCTAssertThrowsError(
            try repository.insertShotWithInitialRevision(makeShot("rejected"), note: "拒绝")
        )
        let counts = try database.read { db in
            (try Shot.fetchCount(db), try Revision.fetchCount(db))
        }
        XCTAssertEqual(counts.0, 0, "初始修订失败时 Shot 必须随事务一起回滚")
        XCTAssertEqual(counts.1, 0)
    }

    func testAppendBuildsLinearChainAndAnnotationAggregates() throws {
        let database = try makeDatabase()
        let repository = ShotRevisionRepository(database: database)
        let first = try repository.insertShotWithInitialRevision(
            makeShot("first"),
            note: "原始"
        )
        let second = try repository.insertShotWithInitialRevision(
            makeShot("second"),
            note: "原始"
        )
        let firstID = try XCTUnwrap(first.id)
        let secondID = try XCTUnwrap(second.id)

        let initial = try XCTUnwrap(repository.latestRevision(shotID: firstID))
        XCTAssertNil(initial.parentID)
        XCTAssertEqual(initial.note, "原始")
        XCTAssertTrue(initial.layers.isEmpty)

        let firstLayer = Layer(kind: .rect, rect: LRect(x: 1, y: 2, w: 3, h: 4))
        let firstEdit = try repository.append(
            shotID: firstID,
            layers: [firstLayer],
            note: "第一次"
        )
        let secondEdit = try repository.append(
            shotID: firstID,
            layers: [firstLayer, firstLayer],
            note: "第二次"
        )

        XCTAssertEqual(firstEdit.parentID, initial.id)
        XCTAssertEqual(secondEdit.parentID, firstEdit.id)
        XCTAssertEqual(try repository.revisions(shotID: firstID).count, 3)
        XCTAssertEqual(try repository.latestRevision(shotID: firstID)?.id, secondEdit.id)
        XCTAssertEqual(try repository.latestRevision(shotID: firstID)?.layers.count, 2)

        XCTAssertEqual(try repository.annotatedCount(), 1, "多次编辑仍只算一张图")
        XCTAssertEqual(
            try repository.annotatedShotIDs(among: [firstID, secondID, firstID]),
            [firstID]
        )
        XCTAssertTrue(try repository.annotatedShotIDs(among: []).isEmpty)

        try database.write { db in
            _ = try Shot.deleteOne(db, key: firstID)
        }
        XCTAssertTrue(try repository.revisions(shotID: firstID).isEmpty, "删图应级联删除修订")
    }
}
