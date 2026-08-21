import Foundation
import GRDB
import XCTest
@testable import IndexApp

final class ShotAssetRepositoryTests: XCTestCase {
    func testUpsertAndTypedQueriesStayInsideRepository() throws {
        let database = try DatabaseQueue()
        try AppDatabase.migrator.migrate(database)
        let shotIDs = try database.write { db -> [Int64] in
            var result: [Int64] = []
            for suffix in ["a", "b"] {
                try db.execute(sql: """
                    INSERT INTO shot (sha256, capturedAt, pixelWidth, pixelHeight)
                    VALUES (?, ?, 10, 10)
                    """, arguments: ["asset-repository-\(suffix)", Date()])
                result.append(db.lastInsertedRowID)
            }
            return result
        }
        let repository = ShotAssetRepository(database: database)

        try repository.upsert(
            shotID: shotIDs[0],
            kind: ShotAssetKind.recording,
            path: "/tmp/first.mp4",
            payload: nil,
            schemaVersion: 1
        )
        try repository.upsert(
            shotID: shotIDs[1],
            kind: ShotAssetKind.recording,
            path: "/tmp/second.mp4",
            payload: nil,
            schemaVersion: 1
        )

        XCTAssertEqual(try repository.count(kind: ShotAssetKind.recording), 2)
        XCTAssertEqual(
            try repository.paths(kind: ShotAssetKind.recording, shotIDs: [shotIDs[0]]),
            [shotIDs[0]: "/tmp/first.mp4"]
        )

        // 同一 Shot + kind 是替换而非追加，防止路径来源漂移。
        try repository.upsert(
            shotID: shotIDs[0],
            kind: ShotAssetKind.recording,
            path: "/tmp/replaced.mp4",
            payload: nil,
            schemaVersion: 1
        )
        XCTAssertEqual(try repository.count(kind: ShotAssetKind.recording), 2)
        XCTAssertEqual(
            try repository.paths(kind: ShotAssetKind.recording, shotIDs: shotIDs)[shotIDs[0]],
            "/tmp/replaced.mp4"
        )

        let moleculePayload = Data("xyz-source".utf8)
        try repository.upsert(
            shotID: shotIDs[0],
            kind: ShotAssetKind.moleculeXYZ,
            path: nil,
            payload: moleculePayload,
            schemaVersion: 1
        )
        XCTAssertEqual(
            try repository.payload(shotID: shotIDs[0], kind: ShotAssetKind.moleculeXYZ),
            moleculePayload
        )
        XCTAssertNil(try repository.payload(
            shotID: shotIDs[1],
            kind: ShotAssetKind.moleculeXYZ
        ))
    }
}
