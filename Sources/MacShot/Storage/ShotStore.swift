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
    /// 分类筛选。nil 表示「全部」。
    /// 图库侧边栏选中的筛选维度。
    enum GalleryFilter: Hashable {
        case all
        case favorites
        case category(String)
        case app(String)
    }

    @Published var filter: GalleryFilter = .all

    /// 收藏的截图 ID。随 reload() 一起刷新，UI 直接读集合，不逐卡片查库。
    @Published private(set) var favoriteIDs: Set<Int64> = []

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

    /// 派生属性的统一落库入口。后处理器只认 key 和值，不知道它最终存在哪。
    ///
    /// `ocr.text` 和 `source.url` 仍写回 shot 表的原有列 —— 它们是一等元数据，
    /// 且既有的 shotFts 索引和详情页都依赖那两列。其余 key 一律进通用属性表，
    /// 所以新增派生能力不需要动 schema。
    func writeAttribute(shotID: Int64, key: String, value: AttributeValue) {
        do {
            switch (key, value) {
            case (AttributeKey.ocrText, .text(let text)):
                try dbQueue.write { db in
                    try db.execute(
                        sql: "UPDATE shot SET ocrText = ? WHERE id = ?",
                        arguments: [text, shotID]
                    )
                }

            case (AttributeKey.sourceURL, .text(let url)):
                try dbQueue.write { db in
                    try db.execute(
                        sql: "UPDATE shot SET sourceURL = ? WHERE id = ?",
                        arguments: [url, shotID]
                    )
                }

            default:
                var record = ShotAttribute(
                    id: nil,
                    shotID: shotID,
                    key: key,
                    text: value.searchableText,
                    payload: value.payload,
                    createdAt: Date()
                )
                try dbQueue.write { db in
                    // 同一张图的同一个 key 只保留最新一份。
                    try ShotAttribute
                        .filter(Column("shotID") == shotID && Column("key") == key)
                        .deleteAll(db)
                    try record.insert(db)
                }
            }
        } catch {
            NSLog("[MacShot] 写入属性 \(key) 失败: \(error)")
            return
        }
        reload()
    }

    /// 删除一条派生属性。取消收藏这类「有即为真」的标记需要真正删除记录，
    /// 而不是写一个空值 —— 筛选和计数都靠 EXISTS 判断。
    func removeAttribute(shotID: Int64, key: String) {
        do {
            try dbQueue.write { db in
                try ShotAttribute
                    .filter(Column("shotID") == shotID && Column("key") == key)
                    .deleteAll(db)
            }
        } catch {
            NSLog("[MacShot] 删除属性 \(key) 失败: \(error)")
            return
        }
        reload()
    }

    // MARK: - 收藏

    func isFavorite(shotID: Int64) -> Bool {
        favoriteIDs.contains(shotID)
    }

    func favoriteCount() -> Int {
        favoriteIDs.count
    }

    func toggleFavorite(_ shot: Shot) {
        guard let id = shot.id else { return }
        if isFavorite(shotID: id) {
            removeAttribute(shotID: id, key: AttributeKey.favorite)
        } else {
            // searchableText 必须是 nil：收藏是标记不是内容，进了 attributeFts
            // 会让全文搜索命中所有收藏。
            writeAttribute(
                shotID: id,
                key: AttributeKey.favorite,
                value: .data(Data([1]), searchableText: nil)
            )
        }
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
    ///
    /// 「读父节点」和「写新节点」必须在**同一个事务**里：分成两次的话，
    /// 图库编辑器和钉图窗口同时提交会拿到相同的 parentID，产生非预期的分叉，
    /// 而下游（latestRevision / EditorView）全部假设修订链是线性的。
    @discardableResult
    func appendRevision(shot: Shot, layers: Layers<ImageSpace>, note: String?) -> Revision? {
        guard let shotID = shot.id else { return nil }

        do {
            return try dbQueue.write { db -> Revision in
                let parent = try Revision
                    .filter(Revision.Columns.shotID == shotID)
                    .order(Column("id").desc)
                    .fetchOne(db)

                var rev = Revision.make(
                    shotID: shotID,
                    parentID: parent?.id,
                    layers: layers.persisted,
                    note: note
                )
                try rev.insert(db)
                return rev
            }
        } catch {
            // 此前是 try?，写失败仍返回一个 id 为 nil 的 Revision，调用方无从分辨。
            NSLog("[MacShot] 追加修订失败: \(error)")
            return nil
        }
    }

    // MARK: - 查询

    func reload() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let filter = filter
        shots = (try? dbQueue.read { db -> [Shot] in
            // 侧边栏筛选是精确匹配的 AND 条件，和 FTS 搜索（子串匹配的 UNION）互不干扰：
            // 搜索决定候选集，筛选再收窄一次。
            let filterClause: String
            var arguments: [String: (any DatabaseValueConvertible)?] = [:]
            switch filter {
            case .all:
                filterClause = ""
            case .favorites:
                filterClause = """
                    AND shot.id IN (
                        SELECT shotID FROM shotAttribute WHERE key = 'favorite'
                    )
                    """
            case .category(let name):
                filterClause = """
                    AND shot.id IN (
                        SELECT shotID FROM shotAttribute
                        WHERE key = 'category' AND text = :filterValue
                    )
                    """
                arguments["filterValue"] = name
            case .app(let name):
                filterClause = "AND shot.appName = :filterValue"
                arguments["filterValue"] = name
            }

            if query.isEmpty {
                return try Shot.fetchAll(db, sql: """
                    SELECT shot.* FROM shot
                    WHERE 1 = 1 \(filterClause)
                    ORDER BY shot.capturedAt DESC
                    LIMIT 500
                    """, arguments: StatementArguments(arguments))
            }
            // trigram 分词器下用带引号的原始串做子串匹配。
            let escaped = query.replacingOccurrences(of: "\"", with: "\"\"")
            arguments["pattern"] = "\"\(escaped)\""
            // 同时搜 shot 本身的字段和派生属性 —— 新的后处理器产出的文本
            // 自动可搜，不需要再改这条查询。
            return try Shot.fetchAll(db, sql: """
                SELECT shot.* FROM shot
                WHERE shot.id IN (
                    SELECT shotFts.rowid FROM shotFts WHERE shotFts MATCH :pattern
                    UNION
                    SELECT shotAttribute.shotID FROM shotAttribute
                    JOIN attributeFts ON attributeFts.rowid = shotAttribute.id
                    WHERE attributeFts MATCH :pattern
                ) \(filterClause)
                ORDER BY shot.capturedAt DESC
                LIMIT 500
                """, arguments: StatementArguments(arguments))
        }) ?? []

        favoriteIDs = Set((try? dbQueue.read { db in
            try Int64.fetchAll(db, sql: """
                SELECT shotID FROM shotAttribute WHERE key = 'favorite'
                """)
        }) ?? [])
    }

    var totalCount: Int {
        (try? dbQueue.read { db in try Shot.fetchCount(db) }) ?? 0
    }

    /// 现有分类及各自的截图数量，按数量降序。图库侧边栏用。
    func categories() -> [(name: String, count: Int)] {
        (try? dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT text AS name, COUNT(*) AS count FROM shotAttribute
                WHERE key = 'category' AND text IS NOT NULL
                GROUP BY text
                ORDER BY count DESC, name ASC
                """).map { (name: $0["name"] as String, count: $0["count"] as Int) }
        }) ?? []
    }

    /// 截图来源 App 及数量，按数量降序。图库侧边栏用；bundleID 用来取真实 App 图标。
    func apps() -> [(name: String, bundleID: String?, count: Int)] {
        (try? dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT appName AS name, MAX(appBundleID) AS bundleID, COUNT(*) AS count
                FROM shot
                WHERE appName IS NOT NULL
                GROUP BY appName
                ORDER BY count DESC, name ASC
                """).map {
                    (name: $0["name"] as String,
                     bundleID: $0["bundleID"] as String?,
                     count: $0["count"] as Int)
                }
        }) ?? []
    }

    /// 读一条派生属性的文本值。详情页展示分类 / 标签用。
    func attributeText(shotID: Int64, key: String) -> String? {
        try? dbQueue.read { db in
            try String.fetchOne(db, sql: """
                SELECT text FROM shotAttribute WHERE shotID = ? AND key = ? LIMIT 1
                """, arguments: [shotID, key])
        }
    }

    /// 还没有指定 key 属性的截图。启动回填用。
    func shotsMissingAttribute(key: String) -> [Shot] {
        (try? dbQueue.read { db in
            try Shot.fetchAll(db, sql: """
                SELECT shot.* FROM shot
                WHERE shot.id NOT IN (
                    SELECT shotID FROM shotAttribute WHERE key = ?
                )
                ORDER BY shot.capturedAt DESC
                """, arguments: [key])
        }) ?? []
    }

    enum StoreError: Error {
        case encodingFailed
    }
}
