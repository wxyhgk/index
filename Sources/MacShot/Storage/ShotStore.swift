import Foundation
import CoreGraphics
import CryptoKit
import GRDB
import Combine

/// 文件 + 数据库的统一入口。
///
/// 磁盘布局：
///   ~/Library/Application Support/MacShot/
///     originals/<sha256>.png   原图，写入后永不修改
///     thumbnails/<sha256>.jpg  缩略图
///     index.sqlite             元数据 / 修订 / 全文索引
@MainActor
final class ShotStore: ObservableObject {

    static let shared = ShotStore()

    @Published private(set) var shots: [Shot] = []
    @Published var searchText: String = ""

    let rootDirectory: URL
    let originalsDirectory: URL
    let thumbnailsDirectory: URL

    private let dbQueue: DatabaseQueue

    private init() {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacShot", isDirectory: true)

        rootDirectory = base
        originalsDirectory = base.appendingPathComponent("originals", isDirectory: true)
        thumbnailsDirectory = base.appendingPathComponent("thumbnails", isDirectory: true)

        for dir in [rootDirectory, originalsDirectory, thumbnailsDirectory] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        do {
            dbQueue = try AppDatabase.makeWriter(at: base.appendingPathComponent("index.sqlite"))
        } catch {
            fatalError("无法打开数据库: \(error)")
        }

        reload()
    }

    // MARK: - 路径

    func originalURL(for shot: Shot) -> URL {
        originalsDirectory.appendingPathComponent(shot.originalFileName)
    }

    func thumbnailURL(for shot: Shot) -> URL {
        thumbnailsDirectory.appendingPathComponent(shot.thumbnailFileName)
    }

    func originalImage(for shot: Shot) -> CGImage? {
        ImageCodec.load(from: originalURL(for: shot))
    }

    // MARK: - 写入

    /// 保存一张新截图：原图落盘（内容寻址，天然去重）+ 元数据入库 + 建立初始空图层修订。
    @discardableResult
    func save(image: CGImage, metadata: CaptureMetadata) throws -> Shot {
        guard let png = ImageCodec.pngData(from: image) else {
            throw StoreError.encodingFailed
        }

        let digest = SHA256.hash(data: png)
        let sha = digest.map { String(format: "%02x", $0) }.joined()

        let originalPath = originalsDirectory.appendingPathComponent("\(sha).png")
        if !FileManager.default.fileExists(atPath: originalPath.path) {
            try png.write(to: originalPath, options: .atomic)
        }

        let thumbPath = thumbnailsDirectory.appendingPathComponent("\(sha).jpg")
        if !FileManager.default.fileExists(atPath: thumbPath.path),
           let thumb = ImageCodec.resized(image, maxDimension: 640),
           let jpg = ImageCodec.jpegData(from: thumb) {
            try? jpg.write(to: thumbPath, options: .atomic)
        }

        var shot = Shot(
            id: nil,
            sha256: sha,
            capturedAt: Date(),
            pixelWidth: image.width,
            pixelHeight: image.height,
            scale: metadata.scale,
            appName: metadata.appName,
            appBundleID: metadata.appBundleID,
            appVersion: metadata.appVersion,
            appBuild: metadata.appBuild,
            windowTitle: metadata.windowTitle,
            sourceURL: metadata.sourceURL,
            displayID: metadata.displayID.map(Int.init),
            displayName: metadata.displayName,
            regionX: metadata.globalRegion.origin.x,
            regionY: metadata.globalRegion.origin.y,
            regionW: metadata.globalRegion.width,
            regionH: metadata.globalRegion.height,
            ocrText: nil
        )

        try dbQueue.write { db in
            try shot.insert(db)
            var initial = Revision.make(shotID: shot.id!, parentID: nil, layers: [], note: "原始")
            try initial.insert(db)
        }

        reload()
        return shot
    }

    /// OCR 异步回填。
    func updateOCR(shotID: Int64, text: String) {
        try? dbQueue.write { db in
            try db.execute(
                sql: "UPDATE shot SET ocrText = ? WHERE id = ?",
                arguments: [text, shotID]
            )
        }
        reload()
    }

    /// 浏览器地址异步回填。
    func updateSourceURL(shotID: Int64, url: String) {
        try? dbQueue.write { db in
            try db.execute(
                sql: "UPDATE shot SET sourceURL = ? WHERE id = ?",
                arguments: [url, shotID]
            )
        }
        reload()
    }

    func delete(_ shot: Shot) {
        guard let id = shot.id else { return }
        _ = try? dbQueue.write { db in
            try Shot.deleteOne(db, key: id)
        }
        // 原图可能被其它记录共享（内容寻址），仅在没有引用时删除。
        let stillReferenced = (try? dbQueue.read { db in
            try Shot.filter(Column("sha256") == shot.sha256).fetchCount(db)
        }) ?? 0
        if stillReferenced == 0 {
            try? FileManager.default.removeItem(at: originalURL(for: shot))
            try? FileManager.default.removeItem(at: thumbnailURL(for: shot))
        }
        reload()
    }

    // MARK: - 修订

    func revisions(for shot: Shot) -> [Revision] {
        guard let id = shot.id else { return [] }
        return (try? dbQueue.read { db in
            try Revision
                .filter(Revision.Columns.shotID == id)
                .order(Revision.Columns.createdAt.asc, Column("id").asc)
                .fetchAll(db)
        }) ?? []
    }

    func latestRevision(for shot: Shot) -> Revision? {
        revisions(for: shot).last
    }

    /// 追加一个新修订。永远不覆盖旧记录 —— 这就是「无限记录」的实现方式。
    @discardableResult
    func appendRevision(shot: Shot, layers: [Layer], note: String?) -> Revision? {
        guard let shotID = shot.id else { return nil }
        let parent = latestRevision(for: shot)
        var rev = Revision.make(shotID: shotID, parentID: parent?.id, layers: layers, note: note)
        try? dbQueue.write { db in
            try rev.insert(db)
        }
        return rev
    }

    // MARK: - 查询

    func reload() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        shots = (try? dbQueue.read { db -> [Shot] in
            if query.isEmpty {
                return try Shot
                    .order(Column("capturedAt").desc)
                    .limit(500)
                    .fetchAll(db)
            }
            // trigram 分词器下用带引号的原始串做子串匹配。
            let escaped = query.replacingOccurrences(of: "\"", with: "\"\"")
            let pattern = "\"\(escaped)\""
            return try Shot.fetchAll(db, sql: """
                SELECT shot.* FROM shot
                JOIN shotFts ON shotFts.rowid = shot.id
                WHERE shotFts MATCH ?
                ORDER BY shot.capturedAt DESC
                LIMIT 500
                """, arguments: [pattern])
        }) ?? []
    }

    enum StoreError: Error {
        case encodingFailed
    }
}
