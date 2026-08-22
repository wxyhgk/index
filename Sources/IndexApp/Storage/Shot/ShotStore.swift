import Foundation
import CoreGraphics
import CryptoKit
import GRDB
import Combine

/// 文件 + 数据库的统一入口。
///
/// 磁盘布局：
///   ~/Library/Application Support/Index/
///     originals/<sha256>.png   原图，写入后永不修改
///     thumbnails/<sha256>.jpg  缩略图
///     index.sqlite             元数据 / 修订 / 全文索引
///
/// 文件布局（按域拆分，全部是同类型扩展）：
///   ShotStore.swift            身份：存储属性、init、路径、写入、删除
///   ShotStore+Collections.swift 收藏 / 专题收藏集 / 标签
///   ShotStore+Revisions.swift   修订链 + 缩略图重画（注入闭包）
///   ShotStore+Query.swift       刷新合并、查询观察、分页、智能筛选计数
///   ShotStore+Search.swift      相似图 / 语义搜索、同源时间线、清理候选
@MainActor
final class ShotStore: ObservableObject {

    static let shared = ShotStore()

    /// 不是 @Published：和 `favoriteIDs` 在 `reload()` 里一起赋值，
    /// 手动只发一次 objectWillChange —— 两个 @Published 各发一次会让
    /// 订阅方（侧边栏聚合查询、详情栏、胶片条……）每轮 reload 级联重查两遍。
    /// 写访问为 `+Query` 扩展（publish / loadNextPage）放开。
    internal(set) var shots: [Shot] = []
    /// 收藏的截图 ID。随 reload() 一起刷新，UI 直接读集合，不逐卡片查库。
    /// 不是 @Published，理由同 `shots`。
    internal(set) var favoriteIDs: Set<Int64> = []

    let rootDirectory: URL
    let originalsDirectory: URL
    let thumbnailsDirectory: URL

    /// 附件 CRUD 的独立、非 MainActor 仓库。ShotStore 只保留领域编解码与刷新语义。
    private let assetRepository: ShotAssetRepository
    /// 列表筛选、分页与清理候选的非 MainActor 查询仓库（读访问为 `+Query` / `+Search` 扩展放开）。
    let queryRepository: ShotQueryRepository
    /// 专题收藏集、成员关系与摘要查询的非 MainActor 仓库（读访问为 `+Collections` 扩展放开）。
    let collectionRepository: ShotCollectionRepository
    /// 派生属性、收藏标记与多值标签的非 MainActor 仓库（读访问为 `+Collections` / `+Query` / `+Search` 扩展放开）。
    let attributeRepository: ShotAttributeRepository
    /// Shot 初始版本、修订链与标注聚合的非 MainActor 仓库（读访问为 `+Revisions` / `+Query` 扩展放开）。
    let revisionRepository: ShotRevisionRepository
    /// Shot 本体查询、来源聚合与删除引用计数的非 MainActor 仓库（读访问为 `+Query` / `+Search` 扩展放开）。
    let metadataRepository: ShotMetadataRepository
    /// 当前页卡片派生信息的后台一致快照（读访问为 `+Collections` 扩展放开）。
    let pageMetadataRepository: ShotPageMetadataRepository
    /// 跨平台便携包只读导出器；不暴露运行中的 SQLite/WAL。
    private let portableLibraryExporter: PortableLibraryExporter
    private let writer: any DatabaseWriter

    /// 当前 `shots` 对应的查询快照。它不是 UI 状态：只用于写入后的自动刷新、
    /// 翻页与无参数兼容入口，确保仓储缓存知道自己装的是什么数据。
    /// 写访问为 `+Query` 扩展（restartLibraryObservation / loadNextPage）放开。
    struct ActiveListQuery: Equatable {
        var text: String
        var filter: ShotFilter
    }
    var activeListQuery = ActiveListQuery(text: "", filter: .all)
    /// 当前查询对应的 GRDB 观察。查询条件改变时取消旧观察并建立新观察。
    /// 写访问为 `+Query` 扩展（restartLibraryObservation）放开。
    var listObservation: AnyDatabaseCancellable?
    /// 防止已经取消的观察把迟到结果发布到新查询会话。
    /// 写访问为 `+Query` 扩展（restartLibraryObservation）放开。
    var listObservationGeneration = 0
    /// 异步首帧等待者。观察被替换或失败时也必须恢复，不能悬挂 continuation。
    var pendingInitialObservation: (() -> Void)?

    /// - Parameters:
    ///   - rootDirectory: 磁盘根目录。默认用真实的 Application Support；测试传临时目录。
    ///   - database: 已迁移好的数据库。默认按根目录打开 index.sqlite；测试传内存库
    ///     （调用方自己先跑 `AppDatabase.migrator`）。
    init(rootDirectory: URL? = nil, database: (any DatabaseWriter)? = nil) {
        let base = rootDirectory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Index", isDirectory: true)

        self.rootDirectory = base
        originalsDirectory = base.appendingPathComponent("originals", isDirectory: true)
        thumbnailsDirectory = base.appendingPathComponent("thumbnails", isDirectory: true)

        for dir in [base, originalsDirectory, thumbnailsDirectory] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        if let database {
            self.writer = database
        } else {
            do {
                self.writer = try AppDatabase.makeWriter(at: base.appendingPathComponent("index.sqlite"))
            } catch {
                fatalError("无法打开数据库: \(error)")
            }
        }
        assetRepository = ShotAssetRepository(database: writer)
        queryRepository = ShotQueryRepository(database: writer)
        collectionRepository = ShotCollectionRepository(database: writer)
        attributeRepository = ShotAttributeRepository(database: writer)
        revisionRepository = ShotRevisionRepository(database: writer)
        metadataRepository = ShotMetadataRepository(database: writer)
        pageMetadataRepository = ShotPageMetadataRepository(database: writer)
        portableLibraryExporter = PortableLibraryExporter(database: writer, rootDirectory: base)

        reload(query: "", filter: .all)
    }

    /// 「库存内容变了」——新增 / 删除 / 筛选重查，即每次 `reload()`。
    ///
    /// 与 `objectWillChange` 的区别很关键：后者**任何**写入都会发，包括
    /// 「给某张图追加一条修订」这种不改变库存的操作。订阅方如果只关心
    /// 「有哪些截图」，订 `objectWillChange` 就会被修订保存反复惊动 ——
    /// 编辑器胶片条正是这样每隔一秒多在主线程上重查一次全库（500 行取回 + 全量解码），
    /// 表现为编辑时点按钮有延迟。
    let libraryDidChange = PassthroughSubject<Void, Never>()

    /// 把「原图 + 图层」渲染成成品的渲染器。**由 App 层注入**。
    ///
    /// 为什么是闭包而不是直接调 `LayerRenderer`：依赖方向不许 Storage 认识 Render
    /// （ARCHITECTURE §1，Render 在 Storage 之上）。注入点在 `AppDelegate`，
    /// 与其它注册表登记在一起。没注入时（测试、命令行）退化为不重画，行为安全。
    var revisionThumbnailRenderer: ((CGImage, Layers<ImageSpace>) -> CGImage)?

    /// 缩略图换了之后要通知谁把内存缓存里那份旧的丢掉。同样由 App 层注入 ——
    /// 缓存住在 UI 层（`ThumbnailCache`），Storage 更不该认识它。
    var thumbnailInvalidator: ((Shot) -> Void)?

    /// 已经没有下一页了。滚到底的触发器据此停手，UI 也据此决定要不要显示加载中。
    /// 写访问为 `+Query` 扩展（publish / loadNextPage）放开。
    internal(set) var hasMorePages = false

    /// 正在取下一页 —— 防止滚动触发器在同一页上重复发起。
    /// 写访问为 `+Query` 扩展（loadNextPage）放开。
    var isLoadingPage = false

    // MARK: - 路径

    func originalURL(for shot: Shot) -> URL {
        originalsDirectory.appendingPathComponent(shot.originalFileName)
    }

    func thumbnailURL(for shot: Shot) -> URL {
        thumbnailsDirectory.appendingPathComponent(shot.thumbnailFileName)
    }

    /// 导出一个可由未来 Windows 客户端导入的独立图库目录。
    /// 目标必须不存在；当前图库与数据库不会被修改。
    @discardableResult
    func exportPortableLibrary(
        to destination: URL,
        exportedAt: Date = Date(),
        producerVersion: String? = nil
    ) async throws -> PortableLibraryManifest {
        try await portableLibraryExporter.export(
            to: destination,
            exportedAt: exportedAt,
            producerVersion: producerVersion
        )
    }

    /// 从便携图库包恢复数据。幂等：按内容哈希去重，重复导入不产生重复数据。
    /// 导入成功后刷新列表。
    @discardableResult
    func importPortableLibrary(at directory: URL) async throws -> PortableLibraryImporter.Report {
        let importer = PortableLibraryImporter(writer: writer, rootDirectory: rootDirectory)
        let report = try await importer.importLibrary(at: directory)
        reload()
        return report
    }

    func originalImage(for shot: Shot) -> CGImage? {
        ImageCodec.load(from: originalURL(for: shot))
    }

    // MARK: - 写入

    /// 保存一张新截图：原图落盘（内容寻址，天然去重）+ 元数据入库 + 建立初始空图层修订。
    @discardableResult
    func save(image: CGImage, metadata: CaptureMetadata) throws -> Shot {
        try save(image: image, metadata: metadata, originalData: nil, originalExtension: nil)
    }

    /// 保存导入的图片。`originalData` 非空时原图按原始字节落盘（SVG 保留矢量文件），
    /// 否则编码为 PNG。`originalExtension` 决定原图文件扩展名。
    @discardableResult
    func save(image: CGImage, metadata: CaptureMetadata, originalData: Data?, originalExtension: String?) throws -> Shot {
        let ext = originalExtension ?? "png"
        let original: Data
        if let originalData, originalExtension != nil {
            original = originalData
        } else {
            guard let png = ImageCodec.pngData(from: image) else {
                throw StoreError.encodingFailed
            }
            original = png
        }

        let digest = SHA256.hash(data: original)
        let sha = digest.map { String(format: "%02x", $0) }.joined()

        let originalPath = originalsDirectory.appendingPathComponent("\(sha).\(ext)")
        if !FileManager.default.fileExists(atPath: originalPath.path) {
            try original.write(to: originalPath, options: .atomic)
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
            ocrText: nil,
            originalExtension: ext
        )

        shot = try revisionRepository.insertShotWithInitialRevision(shot, note: "原始")

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
                try attributeRepository.updateOCRText(text, shotID: shotID)

            case (AttributeKey.sourceURL, .text(let url)):
                try attributeRepository.updateSourceURL(url, shotID: shotID)

            default:
                try attributeRepository.replaceSingle(
                    shotID: shotID,
                    key: key,
                    text: value.searchableText,
                    payload: value.payload
                )
            }
        } catch {
            NSLog("[Index] 写入属性 \(key) 失败: \(error)")
            return
        }
    }

    /// 修改图库显示名称。原图仍是 `originals/<sha256>.png`，不发生文件系统重命名。
    func setCustomTitle(_ title: String?, for shot: Shot) {
        guard let shotID = shot.id else { return }
        do {
            try metadataRepository.updateCustomTitle(
                Shot.normalizedCustomTitle(title),
                shotID: shotID
            )
        } catch {
            NSLog("[Index] 修改截图名称失败: \(error.localizedDescription)")
        }
    }

    /// 把分子来源作为 Shot 的独立附件写入。这里使用可抛错入口，保证“定格”流程
    /// 能在附件失败时撤销刚创建的图片记录，而不是留下没有 XYZ 的半成品。
    func attachMoleculeSource(_ source: MoleculeSourceAttachment, to shot: Shot) throws {
        guard let shotID = shot.id else { throw StoreError.missingShotID }
        let payload = try JSONEncoder().encode(source)
        try assetRepository.upsert(
            shotID: shotID,
            kind: ShotAssetKind.moleculeXYZ,
            path: nil,
            payload: payload,
            schemaVersion: source.schemaVersion
        )
    }

    func moleculeSource(for shot: Shot) -> MoleculeSourceAttachment? {
        guard let shotID = shot.id,
              let payload = try? assetRepository.payload(
                shotID: shotID,
                kind: ShotAssetKind.moleculeXYZ
              )
        else { return nil }
        return try? JSONDecoder().decode(MoleculeSourceAttachment.self, from: payload)
    }

    func attachRecording(at url: URL, to shot: Shot) throws {
        guard let shotID = shot.id else { throw StoreError.missingShotID }
        try assetRepository.upsert(
            shotID: shotID,
            kind: ShotAssetKind.recording,
            path: url.path,
            payload: nil,
            schemaVersion: 1
        )
    }

    func recordingPath(for shot: Shot) -> String? {
        guard let shotID = shot.id else { return nil }
        return recordingPaths(for: [shotID])[shotID]
    }

    /// 当前页批量读取录屏路径，避免网格为每张封面各查一次数据库。
    func recordingPaths(for shotIDs: [Int64]) -> [Int64: String] {
        (try? assetRepository.paths(
            kind: ShotAssetKind.recording,
            shotIDs: shotIDs
        )) ?? [:]
    }

    func recordingCount() -> Int {
        (try? assetRepository.count(kind: ShotAssetKind.recording)) ?? 0
    }

    /// 删除一条派生属性。取消收藏这类「有即为真」的标记需要真正删除记录，
    /// 而不是写一个空值 —— 筛选和计数都靠 EXISTS 判断。
    func removeAttribute(shotID: Int64, key: String) {
        do {
            try attributeRepository.remove(shotID: shotID, key: key)
        } catch {
            NSLog("[Index] 删除属性 \(key) 失败: \(error)")
            return
        }
    }

    // MARK: - 删除

    func delete(_ shot: Shot) {
        delete([shot])
    }

    /// 批量删除：单个事务里删掉所有行并算好引用计数，事务外统一删文件，
    /// 尾部只刷新一次 —— 逐张 delete 是「张数 × (写 + 读 + 全量 reload)」的主线程风暴。
    ///
    /// 引用计数语义与单张版一致：原图内容寻址，同 sha 的多条记录共享一份文件，
    /// 只有事务提交后不再被任何剩余记录引用的 sha 才删文件。删行和查剩余引用
    /// 在同一个事务里完成，比旧的跨事务 read-after-write 更严格。
    func delete(_ shotsToDelete: [Shot]) {
        delete(shotIDs: shotsToDelete.compactMap(\.id))
    }

    func delete(shotIDs: [Int64]) {
        guard !shotIDs.isEmpty else { return }

        // 事务失败时不删任何文件（引用计数没算出来），但必须留日志 ——
        // 这是写路径里唯一会静默失败的一处，其它写路径失败都有 NSLog。
        let orphaned: Set<String>
        do {
            orphaned = try metadataRepository.delete(ids: shotIDs)
        } catch {
            NSLog("[Index] 删除截图 \(shotIDs) 失败: \(error)")
            return
        }

        for sha in orphaned {
            try? FileManager.default.removeItem(
                at: originalsDirectory.appendingPathComponent("\(sha).png"))
            try? FileManager.default.removeItem(
                at: thumbnailsDirectory.appendingPathComponent("\(sha).jpg"))
        }
    }

    // MARK: - 结构化内容

    /// 获取 shot 的结构化内容（纯图片 shot 返回 nil）。
    func content(for shotID: Int64) throws -> ShotContent? {
        try writer.read { db in
            try ShotContent.fetchOne(
                db,
                sql: "SELECT * FROM shotContent WHERE shotID = ?",
                arguments: [shotID]
            )
        }
    }

    /// 获取代码类型的扩展内容。
    func codeContent(for contentID: Int64) throws -> ContentCode? {
        try writer.read { db in
            try ContentCode.fetchOne(db, key: contentID)
        }
    }

    /// 获取 Markdown 类型的扩展内容。
    func markdownContent(for contentID: Int64) throws -> ContentMarkdown? {
        try writer.read { db in
            try ContentMarkdown.fetchOne(db, key: contentID)
        }
    }

    /// 收口三步查询：content → contentID → markdownContent。
    /// 没有存储的 Markdown 时返回 nil，调用方自行决定兜底策略。
    func markdownSource(for shot: Shot) -> String? {
        guard let shotID = shot.id,
              let content = try? content(for: shotID),
              let contentID = content.id,
              let md = try? markdownContent(for: contentID) else { return nil }
        return md.source
    }

    /// 写入 shot 的结构化内容（shotContent + 类型扩展表）。
    /// 幂等：同一 shot 重复调用会覆盖旧内容。
    /// - Parameter payload: 类型相关的载荷，内部 switch 写对应扩展表。
    /// - Parameter updateKind: 是否同步更新 shot.contentKind（截图时 false，手动新建时 true）
    func saveContent(
        for shotID: Int64,
        kind: ContentKind,
        payload: ContentPayload,
        updateKind: Bool = true
    ) throws {
        try writer.write { db in
            let now = Date()
            // ON CONFLICT DO UPDATE 保住 contentID 稳定（INSERT OR REPLACE 会删旧行+插新行，
            // 导致 contentID 变化、级联删除旧扩展行）。
            try db.execute(
                sql: """
                    INSERT INTO shotContent (shotID, kind, confidence, createdAt)
                    VALUES (?, ?, 1.0, ?)
                    ON CONFLICT(shotID) DO UPDATE SET
                        kind = excluded.kind,
                        confidence = excluded.confidence,
                        createdAt = excluded.createdAt
                    """,
                arguments: [shotID, kind.rawValue, now]
            )
            guard let contentID = try Int64.fetchOne(
                db,
                sql: "SELECT id FROM shotContent WHERE shotID = ?",
                arguments: [shotID]
            ) else { throw StoreError.missingShotID }

            // 按 payload 类型写对应扩展表（主键是 contentID，同样用 ON CONFLICT 保幂等）
            switch payload {
            case .markdown(let source):
                try db.execute(
                    sql: """
                        INSERT INTO contentMarkdown (contentID, source) VALUES (?, ?)
                        ON CONFLICT(contentID) DO UPDATE SET source = excluded.source
                        """,
                    arguments: [contentID, source]
                )
            case .code(let text, let language):
                try db.execute(
                    sql: """
                        INSERT INTO contentCode (contentID, language, text) VALUES (?, ?, ?)
                        ON CONFLICT(contentID) DO UPDATE SET
                            language = excluded.language,
                            text = excluded.text
                        """,
                    arguments: [contentID, language, text]
                )
            case .pdf:
                break // PDF 扩展表待建
            }

            // 更新 shot.contentKind
            if updateKind {
                try db.execute(
                    sql: "UPDATE shot SET contentKind = ? WHERE id = ?",
                    arguments: [kind.rawValue, shotID]
                )
            }
        }
    }

    /// 手动新建一个 Markdown 卡片（无原图，contentKind = "markdown"）。
    @discardableResult
    func createMarkdownShot(title: String, source: String) throws -> Shot {
        try writer.write { db in
            let now = Date()
            let sha256 = UUID().uuidString
            // 纯 SQL 插入，避免 GRDB save 后 id 为 nil 的问题
            let shotID = try Int64.fetchOne(
                db,
                sql: """
                    INSERT INTO shot (sha256, capturedAt, pixelWidth, pixelHeight, scale,
                                      windowTitle, regionX, regionY, regionW, regionH,
                                      contentKind, originalExtension)
                    VALUES (?, ?, 0, 0, 1.0, ?, 0, 0, 0, 0, 'markdown', 'png')
                    RETURNING id
                    """,
                arguments: [sha256, now, title]
            ) ?? { throw StoreError.missingShotID }()

            // 写 shotContent + contentMarkdown（ON CONFLICT 保 contentID 稳定）
            try db.execute(
                sql: """
                    INSERT INTO shotContent (shotID, kind, confidence, createdAt)
                    VALUES (?, 'markdown', 1.0, ?)
                    ON CONFLICT(shotID) DO UPDATE SET
                        kind = excluded.kind,
                        confidence = excluded.confidence,
                        createdAt = excluded.createdAt
                    """,
                arguments: [shotID, now]
            )
            guard let contentID = try Int64.fetchOne(
                db,
                sql: "SELECT id FROM shotContent WHERE shotID = ?",
                arguments: [shotID]
            ) else { throw StoreError.missingShotID }
            try db.execute(
                sql: """
                    INSERT INTO contentMarkdown (contentID, source) VALUES (?, ?)
                    ON CONFLICT(contentID) DO UPDATE SET source = excluded.source
                    """,
                arguments: [contentID, source]
            )
            return try Shot.fetchOne(db, key: shotID)!
        }
    }

    enum StoreError: Error {
        case encodingFailed
        case missingShotID
    }

}
