import Foundation
import GRDB
import XCTest
@testable import IndexApp

final class ShotCollectionRepositoryTests: XCTestCase {
    private func makeDatabase() throws -> DatabaseQueue {
        let database = try DatabaseQueue()
        try AppDatabase.migrator.migrate(database)
        return database
    }

    private func insertShots(count: Int, into database: DatabaseQueue) throws -> [Int64] {
        try database.write { db in
            var ids: [Int64] = []
            for index in 0..<count {
                try db.execute(sql: """
                    INSERT INTO shot (sha256, capturedAt, pixelWidth, pixelHeight)
                    VALUES (?, ?, 10, 10)
                    """, arguments: ["collection-repository-\(index)", Date()])
                ids.append(db.lastInsertedRowID)
            }
            return ids
        }
    }

    func testCRUDMapsConstraintsAndKeepsShots() throws {
        let database = try makeDatabase()
        let repository = ShotCollectionRepository(database: database)
        let shotID = try XCTUnwrap(try insertShots(count: 1, into: database).first)

        let collection = try repository.create(name: "MR-TADF 分子", note: "计算化学")
        let collectionID = try XCTUnwrap(collection.id)
        XCTAssertEqual(try repository.count(), 1)

        XCTAssertThrowsError(
            try repository.create(name: "mr-tadf 分子", note: "")
        ) { error in
            XCTAssertEqual(error as? ShotCollectionError, .duplicateName)
        }

        try repository.rename(id: collectionID, to: "发光分子")
        XCTAssertEqual(try repository.summaries().first?.name, "发光分子")
        XCTAssertThrowsError(
            try repository.rename(id: collectionID + 1_000, to: "不存在")
        ) { error in
            XCTAssertEqual(error as? ShotCollectionError, .collectionNotFound)
        }

        try repository.add(shotIDs: [shotID], to: collectionID)
        XCTAssertTrue(try repository.delete(id: collectionID))
        XCTAssertEqual(try repository.count(), 0)
        let remainingShotCount = try database.read { db in try Shot.fetchCount(db) }
        XCTAssertEqual(remainingShotCount, 1, "删除专题集不得删除原截图")
    }

    func testMembershipsAreManyToManyIdempotentAndSummariesAreBounded() throws {
        let database = try makeDatabase()
        let repository = ShotCollectionRepository(database: database)
        let shotIDs = try insertShots(count: 3, into: database)
        let moleculesID = try XCTUnwrap(
            try repository.create(name: "分子", note: "").id
        )
        let papersID = try XCTUnwrap(
            try repository.create(name: "论文", note: "").id
        )

        try repository.add(
            shotIDs: [shotIDs[0], shotIDs[1], shotIDs[2], shotIDs[0]],
            to: moleculesID
        )
        try repository.add(shotIDs: [shotIDs[0]], to: papersID)

        let summaries = Dictionary(
            uniqueKeysWithValues: try repository.summaries(previewLimit: 2).map { ($0.id, $0) }
        )
        XCTAssertEqual(summaries[moleculesID]?.itemCount, 3)
        XCTAssertEqual(summaries[moleculesID]?.previews.count, 2)
        XCTAssertEqual(summaries[papersID]?.itemCount, 1)

        let memberships = try repository.memberships(shotIDs: shotIDs + [shotIDs[0]])
        XCTAssertEqual(memberships[shotIDs[0]], [moleculesID, papersID])
        XCTAssertEqual(memberships[shotIDs[1]], [moleculesID])

        try repository.remove(
            shotIDs: [shotIDs[0], shotIDs[0], shotIDs[2]],
            from: moleculesID
        )
        XCTAssertEqual(
            try repository.memberships(shotIDs: shotIDs)[shotIDs[0]],
            [papersID]
        )
        XCTAssertEqual(try repository.summaries().first { $0.id == moleculesID }?.itemCount, 1)

        XCTAssertThrowsError(
            try repository.add(shotIDs: [shotIDs[0]], to: 999_999)
        ) { error in
            XCTAssertEqual(error as? ShotCollectionError, .collectionNotFound)
        }
    }

    func testSummariesScaleAcrossManyCollectionsAndKeepPreviewOrder() throws {
        let database = try makeDatabase()
        let repository = ShotCollectionRepository(database: database)
        let shotIDs = try insertShots(count: 4, into: database)

        for index in 0..<24 {
            let id = try XCTUnwrap(repository.create(name: "专题 \(index)", note: "").id)
            try repository.add(shotIDs: shotIDs, to: id)
        }

        let summaries = try repository.summaries(previewLimit: 2)
        XCTAssertEqual(summaries.count, 24)
        XCTAssertTrue(summaries.allSatisfy { $0.itemCount == 4 })
        XCTAssertTrue(summaries.allSatisfy { $0.previews.count == 2 })
        XCTAssertTrue(summaries.allSatisfy { summary in
            Set(summary.previews.compactMap(\.id)).isSubset(of: Set(shotIDs))
        })
    }

    func testLargeMembershipReadsAndRemovalsAreChunked() async throws {
        let database = try makeDatabase()
        let repository = ShotCollectionRepository(database: database)
        let shotIDs = try insertShots(count: 1_205, into: database)
        let collectionID = try XCTUnwrap(repository.create(name: "大型专题", note: "").id)
        try repository.add(shotIDs: shotIDs, to: collectionID)

        let memberships = try repository.memberships(shotIDs: shotIDs)
        XCTAssertEqual(memberships.count, shotIDs.count)
        let counts = try await repository.membershipCountsInBackground(shotIDs: shotIDs)
        XCTAssertEqual(counts[collectionID], shotIDs.count)

        try repository.remove(shotIDs: shotIDs, from: collectionID)
        XCTAssertTrue(try repository.memberships(shotIDs: shotIDs).isEmpty)
    }
}
