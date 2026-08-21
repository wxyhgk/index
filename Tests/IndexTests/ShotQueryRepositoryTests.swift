import Foundation
import GRDB
import XCTest
@testable import IndexApp

final class ShotQueryRepositoryTests: XCTestCase {
    func testRecordingScopeAndCursorAreRepositoryConcerns() throws {
        let database = try DatabaseQueue()
        try AppDatabase.migrator.migrate(database)
        let capturedAt = Date(timeIntervalSince1970: 1_000)
        let shotIDs = try database.write { db -> [Int64] in
            var result: [Int64] = []
            for index in 0..<3 {
                try db.execute(sql: """
                    INSERT INTO shot (
                        sha256, capturedAt, pixelWidth, pixelHeight, windowTitle
                    ) VALUES (?, ?, 10, 10, ?)
                    """, arguments: ["query-repository-\(index)", capturedAt, "录屏 \(index)"])
                result.append(db.lastInsertedRowID)
            }
            return result
        }
        let assets = ShotAssetRepository(database: database)
        for id in shotIDs {
            try assets.upsert(
                shotID: id,
                kind: ShotAssetKind.recording,
                path: "/tmp/\(id).mp4",
                payload: nil,
                schemaVersion: 1
            )
        }
        let repository = ShotQueryRepository(database: database)

        let firstPage = try repository.shots(
            query: "",
            filter: .recordings,
            limit: 2
        )
        XCTAssertEqual(firstPage.compactMap(\.id), Array(shotIDs.reversed().prefix(2)))

        let last = try XCTUnwrap(firstPage.last)
        let cursor = ShotQueryRepository.PageCursor(
            capturedAt: last.capturedAt,
            id: try XCTUnwrap(last.id)
        )
        let secondPage = try repository.shots(
            query: "录屏",
            filter: .recordings,
            after: cursor,
            limit: 2
        )
        XCTAssertEqual(secondPage.compactMap(\.id), [shotIDs[0]])
    }
}
