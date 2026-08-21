import Foundation
import GRDB
import XCTest
@testable import IndexApp

final class ShotAttributeRepositoryTests: XCTestCase {
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
                    """, arguments: [
                        "attribute-repository-\(index)",
                        Date(timeIntervalSince1970: TimeInterval(1_000 + index)),
                    ])
                ids.append(db.lastInsertedRowID)
            }
            return ids
        }
    }

    func testSingleValueAttributesReplaceAndShotColumnsUpdate() throws {
        let database = try makeDatabase()
        let shotIDs = try insertShots(count: 2, into: database)
        let repository = ShotAttributeRepository(database: database)

        try repository.updateOCRText("识别文本", shotID: shotIDs[0])
        try repository.updateSourceURL("https://example.com", shotID: shotIDs[0])
        let updated = try database.read { db in
            try Shot.fetchOne(db, key: shotIDs[0])
        }
        XCTAssertEqual(updated?.ocrText, "识别文本")
        XCTAssertEqual(updated?.sourceURL, "https://example.com")

        try repository.replaceSingle(
            shotID: shotIDs[0],
            key: AttributeKey.category,
            text: "文档",
            payload: nil
        )
        try repository.replaceSingle(
            shotID: shotIDs[0],
            key: AttributeKey.category,
            text: "科研",
            payload: nil
        )

        XCTAssertEqual(
            try repository.text(shotID: shotIDs[0], key: AttributeKey.category),
            "科研"
        )
        XCTAssertEqual(
            try repository.texts(key: AttributeKey.category, shotIDs: shotIDs),
            [shotIDs[0]: "科研"]
        )
        let categoryRows = try database.read { db in
            try ShotAttribute
                .filter(Column("shotID") == shotIDs[0]
                    && Column("key") == AttributeKey.category)
                .fetchCount(db)
        }
        XCTAssertEqual(categoryRows, 1, "单值属性必须替换旧行而不是追加")

        try repository.remove(shotID: shotIDs[0], key: AttributeKey.category)
        XCTAssertNil(try repository.text(shotID: shotIDs[0], key: AttributeKey.category))
    }

    func testPayloadSyncAndBackgroundReadsShareSemantics() async throws {
        let database = try makeDatabase()
        let shotIDs = try insertShots(count: 2, into: database)
        let repository = ShotAttributeRepository(database: database)
        let payload = Data([1, 2, 3, 4])

        try repository.replaceSingle(
            shotID: shotIDs[0],
            key: AttributeKey.featurePrint,
            text: nil,
            payload: payload
        )

        XCTAssertEqual(
            try repository.payload(shotID: shotIDs[0], key: AttributeKey.featurePrint),
            payload
        )
        let synchronous = try repository.payloads(key: AttributeKey.featurePrint)
        let background = try await repository.payloadsInBackground(
            key: AttributeKey.featurePrint
        )
        XCTAssertEqual(synchronous.map(\.shotID), background.map(\.shotID))
        XCTAssertEqual(synchronous.map(\.payload), background.map(\.payload))
        XCTAssertEqual(
            try repository.shotsMissing(key: AttributeKey.featurePrint).compactMap(\.id),
            [shotIDs[1]]
        )
    }

    func testTagsFavoritesAndFTSStayConsistent() async throws {
        let database = try makeDatabase()
        let shotIDs = try insertShots(count: 2, into: database)
        let repository = ShotAttributeRepository(database: database)

        try repository.addTag(shotID: shotIDs[0], name: "chemistry")
        try repository.addTag(shotID: shotIDs[0], name: "molecule")
        try repository.addTag(shotID: shotIDs[1], name: "chemistry")
        try repository.addTag(shotID: shotIDs[1], name: "chemistry")
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: try repository.textCounts(key: AttributeKey.tag)),
            ["chemistry": 2, "molecule": 1]
        )

        // shot 0 已有目标名：重命名时必须合并，而不是生成两条 molecule。
        try repository.renameTag("chemistry", to: "molecule")
        XCTAssertEqual(Set(try repository.tags(shotID: shotIDs[0])), ["molecule"])
        XCTAssertEqual(Set(try repository.tags(shotID: shotIDs[1])), ["molecule"])

        let queryRepository = ShotQueryRepository(database: database)
        XCTAssertTrue(try queryRepository.shots(
            query: "chemistry",
            filter: .all,
            limit: 10
        ).isEmpty, "重命名必须同步清除 FTS 旧词")
        XCTAssertEqual(
            Set(try queryRepository.shots(
                query: "molecule",
                filter: .all,
                limit: 10
            ).compactMap(\.id)),
            Set(shotIDs),
            "重命名必须同步写入 FTS 新词"
        )

        try repository.replaceSingle(
            shotID: shotIDs[0],
            key: AttributeKey.favorite,
            text: nil,
            payload: Data([1])
        )
        let backgroundFavorites = try await repository.favoriteIDsInBackground()
        XCTAssertEqual(try repository.favoriteIDs(), [shotIDs[0]])
        XCTAssertEqual(backgroundFavorites, [shotIDs[0]])
        XCTAssertEqual(
            try repository.favoritePreviews(limit: 1).compactMap(\.id),
            [shotIDs[0]]
        )

        try repository.deleteTag("molecule")
        XCTAssertTrue(try repository.textCounts(key: AttributeKey.tag).isEmpty)
        XCTAssertTrue(try repository.tags(shotID: shotIDs[0]).isEmpty)
    }

    func testLargeFavoriteMutationUsesOneChunkSafeTransaction() throws {
        let database = try makeDatabase()
        let shotIDs = try insertShots(count: 1_205, into: database)
        let repository = ShotAttributeRepository(database: database)

        try repository.setFavorite(shotIDs: shotIDs + [shotIDs[0], 9_999_999], isFavorite: true)
        XCTAssertEqual(try repository.favoriteIDs(), Set(shotIDs), "重复和陈旧 ID 必须安全过滤")

        let removed = Array(shotIDs.prefix(705))
        try repository.setFavorite(shotIDs: removed, isFavorite: false)
        XCTAssertEqual(try repository.favoriteIDs(), Set(shotIDs.dropFirst(removed.count)))
    }
}
