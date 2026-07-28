import XCTest
import CoreGraphics
import GRDB
@testable import MacShot

/// ShotStore 的行为安全网：清理候选的豁免规则、批量删除的引用计数。
/// 全部用内存库 + 临时目录，不碰真实的 Application Support。
@MainActor
final class ShotStoreTests: XCTestCase {

    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacShotTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
    }

    /// 内存库 + 临时根目录的 ShotStore。返回 dbQueue 供测试直接改库（比如回填拍摄时间）。
    private func makeStore() throws -> (store: ShotStore, dbQueue: DatabaseQueue) {
        let dbQueue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(dbQueue)
        return (ShotStore(rootDirectory: tempRoot, database: dbQueue), dbQueue)
    }

    /// 纯色小图。gray 不同 → 像素不同 → sha256 不同。
    private func makeImage(gray: CGFloat) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: gray, green: gray, blue: gray, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        return try XCTUnwrap(context.makeImage())
    }

    /// 把一批截图的拍摄时间改到过去 —— save() 固定写当前时间，测试需要老图。
    private func backdate(_ ids: [Int64], to date: Date, in dbQueue: DatabaseQueue) throws {
        try dbQueue.write { db in
            for id in ids {
                try db.execute(
                    sql: "UPDATE shot SET capturedAt = ? WHERE id = ?",
                    arguments: [date, id]
                )
            }
        }
    }

    // MARK: - 清理候选

    /// 有标签 / 收藏 / 修订（标注过）的截图不进清理候选；过期且无保护的进。
    func testCleanupCandidatesExemptProtectedShots() throws {
        let (store, dbQueue) = try makeStore()

        let plain = try store.save(image: makeImage(gray: 0.1), metadata: CaptureMetadata())
        let tagged = try store.save(image: makeImage(gray: 0.2), metadata: CaptureMetadata())
        let favorited = try store.save(image: makeImage(gray: 0.3), metadata: CaptureMetadata())
        let annotated = try store.save(image: makeImage(gray: 0.4), metadata: CaptureMetadata())
        let recent = try store.save(image: makeImage(gray: 0.5), metadata: CaptureMetadata())

        // 前四张回填成 10 天前的老图；recent 保持当前时间。
        let oldDate = Date().addingTimeInterval(-10 * 86_400)
        try backdate(
            [plain.id!, tagged.id!, favorited.id!, annotated.id!],
            to: oldDate, in: dbQueue
        )

        store.addTag(shotID: tagged.id!, "工作")
        store.toggleFavorite(favorited)
        let layer = Layer(kind: .rect, rect: LRect(x: 0, y: 0, w: 4, h: 4))
        XCTAssertNotNil(store.appendRevision(
            shot: annotated, layers: Layers<ImageSpace>([layer]), note: nil
        ))

        let cutoff = Date().addingTimeInterval(-86_400)
        let candidates = store.cleanupCandidates(olderThan: cutoff, limit: 10)

        XCTAssertEqual(candidates.map(\.id), [plain.id], "只有过期且无任何保护的截图进候选")
        _ = recent // recent 未过期，不应出现 —— 上面的相等断言已覆盖。
    }

    // MARK: - 批量删除的引用计数

    /// 同 sha 两张截图：删一张文件保留，删第二张文件消失。
    func testBatchDeleteKeepsSharedOriginalUntilLastReference() throws {
        let (store, _) = try makeStore()
        let image = try makeImage(gray: 0.6)

        let first = try store.save(image: image, metadata: CaptureMetadata())
        let second = try store.save(image: image, metadata: CaptureMetadata())
        XCTAssertEqual(first.sha256, second.sha256, "同内容必须内容寻址去重")
        XCTAssertNotEqual(first.id, second.id)

        let originalPath = store.originalURL(for: first).path
        let thumbnailPath = store.thumbnailURL(for: first).path
        XCTAssertTrue(FileManager.default.fileExists(atPath: originalPath))

        store.delete([first])
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: originalPath),
            "sha 仍被另一条记录引用，原图必须保留"
        )
        XCTAssertEqual(store.totalCount, 1)

        store.delete([second])
        XCTAssertFalse(FileManager.default.fileExists(atPath: originalPath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: thumbnailPath))
        XCTAssertEqual(store.totalCount, 0)
    }

    /// 同一批里同时删掉同 sha 的所有记录：同一事务里算引用计数，文件删干净。
    func testBatchDeleteRemovesFileWhenAllReferencesGoInOneBatch() throws {
        let (store, _) = try makeStore()
        let shared = try makeImage(gray: 0.7)

        let first = try store.save(image: shared, metadata: CaptureMetadata())
        let second = try store.save(image: shared, metadata: CaptureMetadata())
        let survivor = try store.save(image: makeImage(gray: 0.8), metadata: CaptureMetadata())

        let sharedPath = store.originalURL(for: first).path
        let survivorPath = store.originalURL(for: survivor).path

        store.delete([first, second])

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: sharedPath),
            "全部引用在同一批里删光，文件必须消失"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: survivorPath), "无关截图不受影响")
        XCTAssertEqual(store.totalCount, 1)
    }
}
