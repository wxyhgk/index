import Foundation
import GRDB
import XCTest
@testable import MacShot

final class ShotMetadataRepositoryTests: XCTestCase {
    private func makeDatabase() throws -> DatabaseQueue {
        let database = try DatabaseQueue()
        try AppDatabase.migrator.migrate(database)
        return database
    }

    private func insertShot(
        _ suffix: String,
        sha256: String? = nil,
        capturedAt: Date,
        appName: String? = nil,
        bundleID: String? = nil,
        windowTitle: String? = nil,
        sourceURL: String? = nil,
        into database: DatabaseQueue
    ) throws -> Shot {
        var shot = Shot(
            id: nil,
            sha256: sha256 ?? "metadata-repository-\(suffix)",
            capturedAt: capturedAt,
            pixelWidth: 10,
            pixelHeight: 10,
            scale: 2,
            appName: appName,
            appBundleID: bundleID,
            appVersion: nil,
            appBuild: nil,
            windowTitle: windowTitle,
            sourceURL: sourceURL,
            displayID: nil,
            displayName: nil,
            regionX: 0,
            regionY: 0,
            regionW: 10,
            regionH: 10,
            ocrText: nil
        )
        try database.write { db in try shot.insert(db) }
        return shot
    }

    func testDirectQueriesAndDeleteReferenceCounting() throws {
        let database = try makeDatabase()
        let repository = ShotMetadataRepository(database: database)
        let base = Date(timeIntervalSince1970: 1_000)
        let first = try insertShot(
            "first",
            sha256: "shared-content",
            capturedAt: base,
            into: database
        )
        let second = try insertShot(
            "second",
            sha256: "shared-content",
            capturedAt: base.addingTimeInterval(1),
            into: database
        )
        let survivor = try insertShot(
            "survivor",
            capturedAt: base.addingTimeInterval(2),
            into: database
        )
        let firstID = try XCTUnwrap(first.id)
        let secondID = try XCTUnwrap(second.id)
        let survivorID = try XCTUnwrap(survivor.id)

        XCTAssertEqual(try repository.count(), 3)
        XCTAssertEqual(try repository.recent(limit: 2).compactMap(\.id), [survivorID, secondID])
        XCTAssertTrue(try repository.exists(id: firstID))
        XCTAssertEqual(
            Set(try repository.shots(ids: [survivorID, firstID, firstID]).compactMap(\.id)),
            [firstID, survivorID]
        )

        XCTAssertTrue(try repository.delete([first]).isEmpty, "同 SHA 仍有引用时不能删文件")
        XCTAssertFalse(try repository.exists(id: firstID))
        XCTAssertEqual(try repository.count(), 2)

        XCTAssertEqual(try repository.delete([second]), ["shared-content"])
        XCTAssertTrue(try repository.exists(id: survivorID))
        XCTAssertEqual(try repository.count(), 1)
    }

    func testCapturedAppsUseStableIdentityAndBoundedPreviews() throws {
        let database = try makeDatabase()
        let repository = ShotMetadataRepository(database: database)
        let base = Date(timeIntervalSince1970: 2_000)
        var mainShots: [Shot] = []
        for index in 0..<4 {
            mainShots.append(try insertShot(
                "main-\(index)",
                capturedAt: base.addingTimeInterval(TimeInterval(index)),
                appName: index == 0 ? "旧名称" : "新名称",
                bundleID: "com.example.main",
                into: database
            ))
        }
        _ = try insertShot(
            "other-bundle",
            capturedAt: base.addingTimeInterval(10),
            appName: "新名称",
            bundleID: "com.example.other",
            into: database
        )
        _ = try insertShot(
            "no-bundle",
            capturedAt: base.addingTimeInterval(11),
            appName: "新名称",
            bundleID: nil,
            into: database
        )

        let apps = try repository.capturedApps(previewLimit: 2)
        XCTAssertEqual(apps.count, 3)
        let main = try XCTUnwrap(apps.first { $0.bundleID == "com.example.main" })
        XCTAssertEqual(main.name, "新名称")
        XCTAssertEqual(main.captureCount, 4)
        XCTAssertEqual(
            main.previews.compactMap(\.id),
            mainShots.suffix(2).reversed().compactMap(\.id)
        )
        XCTAssertEqual(main.lastCapturedAt, base.addingTimeInterval(3))
    }

    func testRelatedQueriesOnlyReturnBoundedCandidates() throws {
        let database = try makeDatabase()
        let repository = ShotMetadataRepository(database: database)
        let base = Date(timeIntervalSince1970: 3_000)
        let urls = [
            "https://example.com/a",
            "https://example.com/a#section",
            "https://example.com/a/",
            "https://example.com/abc",
            "https://other.example/a",
        ]
        var shots: [Shot] = []
        for (index, url) in urls.enumerated() {
            shots.append(try insertShot(
                "url-\(index)",
                capturedAt: base.addingTimeInterval(TimeInterval(index)),
                sourceURL: url,
                into: database
            ))
        }

        XCTAssertEqual(
            try repository.relatedBySourcePrefix("https://example.com/a").compactMap(\.id),
            shots.prefix(4).compactMap(\.id),
            "仓储只缩小前缀候选，/abc 由上层归一化精确判定排除"
        )

        let titled = try insertShot(
            "app-title",
            capturedAt: base,
            appName: "App",
            bundleID: "com.example.app",
            windowTitle: "窗口 A",
            into: database
        )
        let untitled = try insertShot(
            "app-other-title",
            capturedAt: base.addingTimeInterval(1),
            appName: "App",
            bundleID: "com.example.app",
            windowTitle: "窗口 B",
            into: database
        )
        XCTAssertEqual(
            try repository.related(
                bundleID: "com.example.app",
                windowTitle: "窗口 A"
            ).compactMap(\.id),
            [titled.id]
        )
        XCTAssertEqual(
            Set(try repository.related(
                bundleID: "com.example.app",
                windowTitle: nil
            ).compactMap(\.id)),
            Set([titled.id, untitled.id].compactMap { $0 })
        )
    }

    func testUpdateCustomTitleOnlyChangesMetadata() throws {
        let database = try makeDatabase()
        let repository = ShotMetadataRepository(database: database)
        let shot = try insertShot(
            "rename",
            capturedAt: Date(timeIntervalSince1970: 4_000),
            windowTitle: "原始标题",
            into: database
        )
        let id = try XCTUnwrap(shot.id)

        try repository.updateCustomTitle("自定义图库名", shotID: id)

        try database.read { db in
            let updated = try XCTUnwrap(Shot.fetchOne(db, key: id))
            XCTAssertEqual(updated.customTitle, "自定义图库名")
            XCTAssertEqual(updated.sha256, shot.sha256)
            XCTAssertEqual(updated.windowTitle, "原始标题")
        }
    }
}
