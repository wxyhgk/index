import Foundation
import GRDB
import XCTest
@testable import IndexApp

final class ShotPageMetadataRepositoryTests: XCTestCase {
    func testFetchReturnsAllCardMetadataFromOneSnapshot() async throws {
        let database = try DatabaseQueue()
        try AppDatabase.migrator.migrate(database)
        let ids = try await database.write { db -> [Int64] in
            var result: [Int64] = []
            for index in 0..<2 {
                try db.execute(sql: """
                    INSERT INTO shot (sha256, capturedAt, pixelWidth, pixelHeight)
                    VALUES (?, ?, 20, 10)
                    """, arguments: ["page-metadata-\(index)", Date().addingTimeInterval(Double(index))])
                result.append(db.lastInsertedRowID)
            }
            try db.execute(sql: """
                INSERT INTO shotAttribute (shotID, key, text, createdAt)
                VALUES (?, ?, ?, ?)
                """, arguments: [result[0], AttributeKey.category, "计算化学", Date()])
            for note in ["原始", "标注"] {
                try db.execute(sql: """
                    INSERT INTO revision (shotID, createdAt, note, layersJSON)
                    VALUES (?, ?, ?, '[]')
                    """, arguments: [result[0], Date(), note])
            }
            try db.execute(sql: """
                INSERT INTO revision (shotID, createdAt, note, layersJSON)
                VALUES (?, ?, '原始', '[]')
                """, arguments: [result[1], Date()])
            try db.execute(sql: """
                INSERT INTO shotAsset (shotID, kind, path, schemaVersion, createdAt, updatedAt)
                VALUES (?, ?, ?, 1, ?, ?)
                """, arguments: [result[1], ShotAssetKind.recording, "/tmp/demo.mp4", Date(), Date()])
            return result
        }

        let collections = ShotCollectionRepository(database: database)
        let collectionID = try XCTUnwrap(try collections.create(name: "MR-TADF", note: "").id)
        try collections.add(shotIDs: ids, to: collectionID)

        let repository = ShotPageMetadataRepository(database: database)
        let snapshot = try await repository.fetchInBackground(shotIDs: ids)

        XCTAssertEqual(snapshot.categoriesByShot[ids[0]], "计算化学")
        XCTAssertEqual(snapshot.annotatedShotIDs, [ids[0]])
        XCTAssertEqual(snapshot.recordingPathsByShot[ids[1]], "/tmp/demo.mp4")
        XCTAssertEqual(snapshot.collectionSummaries.first?.id, collectionID)
        XCTAssertEqual(snapshot.collectionSummaries.first?.itemCount, 2)
        XCTAssertTrue(snapshot.collectionSummaries.first?.previews.isEmpty == true)
        XCTAssertEqual(snapshot.collectionIDsByShot[ids[0]], [collectionID])
        XCTAssertEqual(snapshot.collectionIDsByShot[ids[1]], [collectionID])
    }

    func testEmptyPageStillReturnsCollectionsForMenus() async throws {
        let database = try DatabaseQueue()
        try AppDatabase.migrator.migrate(database)
        let collections = ShotCollectionRepository(database: database)
        _ = try collections.create(name: "空专题", note: "")

        let snapshot = try await ShotPageMetadataRepository(database: database)
            .fetchInBackground(shotIDs: [])

        XCTAssertEqual(snapshot.collectionSummaries.map(\.name), ["空专题"])
        XCTAssertTrue(snapshot.categoriesByShot.isEmpty)
        XCTAssertTrue(snapshot.collectionIDsByShot.isEmpty)
    }

    func testFetchChunksLargePagesWithoutLosingBoundaryMetadata() async throws {
        let database = try DatabaseQueue()
        try AppDatabase.migrator.migrate(database)
        let ids = try await database.write { db -> [Int64] in
            var result: [Int64] = []
            for index in 0..<1_005 {
                try db.execute(sql: """
                    INSERT INTO shot (sha256, capturedAt, pixelWidth, pixelHeight)
                    VALUES (?, ?, 20, 10)
                    """, arguments: ["large-page-\(index)", Date().addingTimeInterval(Double(index))])
                result.append(db.lastInsertedRowID)
            }
            for index in [0, 499, 500, 1_004] {
                try db.execute(sql: """
                    INSERT INTO shotAttribute (shotID, key, text, createdAt)
                    VALUES (?, ?, ?, ?)
                    """, arguments: [result[index], AttributeKey.category, "分类-\(index)", Date()])
            }
            for note in ["原始", "标注"] {
                try db.execute(sql: """
                    INSERT INTO revision (shotID, createdAt, note, layersJSON)
                    VALUES (?, ?, ?, '[]')
                    """, arguments: [result[1_004], Date(), note])
            }
            try db.execute(sql: """
                INSERT INTO shotAsset (shotID, kind, path, schemaVersion, createdAt, updatedAt)
                VALUES (?, ?, ?, 1, ?, ?)
                """, arguments: [result[500], ShotAssetKind.recording, "/tmp/chunk-boundary.mp4", Date(), Date()])
            return result
        }

        let collections = ShotCollectionRepository(database: database)
        let collectionID = try XCTUnwrap(try collections.create(name: "大专题", note: "").id)
        try collections.add(shotIDs: ids, to: collectionID)

        let snapshot = try await ShotPageMetadataRepository(database: database)
            .fetchInBackground(shotIDs: ids)

        XCTAssertEqual(snapshot.categoriesByShot[ids[0]], "分类-0")
        XCTAssertEqual(snapshot.categoriesByShot[ids[499]], "分类-499")
        XCTAssertEqual(snapshot.categoriesByShot[ids[500]], "分类-500")
        XCTAssertEqual(snapshot.categoriesByShot[ids[1_004]], "分类-1004")
        XCTAssertTrue(snapshot.annotatedShotIDs.contains(ids[1_004]))
        XCTAssertEqual(snapshot.recordingPathsByShot[ids[500]], "/tmp/chunk-boundary.mp4")
        XCTAssertEqual(snapshot.collectionIDsByShot[ids[0]], [collectionID])
        XCTAssertEqual(snapshot.collectionIDsByShot[ids[1_004]], [collectionID])
    }

    func testMergingPageMetadataKeepsPrefixAndUsesNewestCollectionSummary() {
        let prefix = ShotPageMetadata(
            categoriesByShot: [1: "旧分类"],
            annotatedShotIDs: [1],
            recordingPathsByShot: [1: "/tmp/old.mp4"],
            collectionSummaries: [],
            collectionIDsByShot: [1: [10]]
        )
        let suffix = ShotPageMetadata(
            categoriesByShot: [2: "新分类"],
            annotatedShotIDs: [2],
            recordingPathsByShot: [2: "/tmp/new.mp4"],
            collectionSummaries: [],
            collectionIDsByShot: [2: [20]]
        )

        let merged = prefix.merging(suffix)

        XCTAssertEqual(merged.categoriesByShot, [1: "旧分类", 2: "新分类"])
        XCTAssertEqual(merged.annotatedShotIDs, [1, 2])
        XCTAssertEqual(merged.recordingPathsByShot, [1: "/tmp/old.mp4", 2: "/tmp/new.mp4"])
        XCTAssertEqual(merged.collectionIDsByShot, [1: [10], 2: [20]])
    }
}
