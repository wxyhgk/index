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

    /// 不是 @Published：和 `favoriteIDs` 在 `reload()` 里一起赋值，
    /// 手动只发一次 objectWillChange —— 两个 @Published 各发一次会让
    /// 订阅方（侧边栏聚合查询、详情栏、胶片条……）每轮 reload 级联重查两遍。
    private(set) var shots: [Shot] = []
    /// 收藏的截图 ID。随 reload() 一起刷新，UI 直接读集合，不逐卡片查库。
    /// 不是 @Published，理由同 `shots`。
    private(set) var favoriteIDs: Set<Int64> = []

    let rootDirectory: URL
    let originalsDirectory: URL
    let thumbnailsDirectory: URL

    /// 附件 CRUD 的独立、非 MainActor 仓库。ShotStore 只保留领域编解码与刷新语义。
    private let assetRepository: ShotAssetRepository
    /// 列表筛选、分页与清理候选的非 MainActor 查询仓库。
    private let queryRepository: ShotQueryRepository
    /// 专题收藏集、成员关系与摘要查询的非 MainActor 仓库。
    private let collectionRepository: ShotCollectionRepository
    /// 派生属性、收藏标记与多值标签的非 MainActor 仓库。
    private let attributeRepository: ShotAttributeRepository
    /// Shot 初始版本、修订链与标注聚合的非 MainActor 仓库。
    private let revisionRepository: ShotRevisionRepository
    /// Shot 本体查询、来源聚合与删除引用计数的非 MainActor 仓库。
    private let metadataRepository: ShotMetadataRepository

    /// 当前 `shots` 对应的查询快照。它不是 UI 状态：只用于写入后的自动刷新、
    /// 翻页与无参数兼容入口，确保仓储缓存知道自己装的是什么数据。
    private struct ActiveListQuery: Equatable {
        var text: String
        var filter: ShotFilter
    }
    private var activeListQuery = ActiveListQuery(text: "", filter: .all)
    /// 当前查询对应的 GRDB 观察。查询条件改变时取消旧观察并建立新观察。
    private var listObservation: AnyDatabaseCancellable?
    /// 防止已经取消的观察把迟到结果发布到新查询会话。
    private var listObservationGeneration = 0
    /// 异步首帧等待者。观察被替换或失败时也必须恢复，不能悬挂 continuation。
    private var pendingInitialObservation: (() -> Void)?

    /// - Parameters:
    ///   - rootDirectory: 磁盘根目录。默认用真实的 Application Support；测试传临时目录。
    ///   - database: 已迁移好的数据库。默认按根目录打开 index.sqlite；测试传内存库
    ///     （调用方自己先跑 `AppDatabase.migrator`）。
    init(rootDirectory: URL? = nil, database: (any DatabaseWriter)? = nil) {
        let base = rootDirectory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacShot", isDirectory: true)

        self.rootDirectory = base
        originalsDirectory = base.appendingPathComponent("originals", isDirectory: true)
        thumbnailsDirectory = base.appendingPathComponent("thumbnails", isDirectory: true)

        for dir in [base, originalsDirectory, thumbnailsDirectory] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        let writer: any DatabaseWriter
        if let database {
            writer = database
        } else {
            do {
                writer = try AppDatabase.makeWriter(at: base.appendingPathComponent("index.sqlite"))
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

        reload(query: "", filter: .all)
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
            NSLog("[MacShot] 写入属性 \(key) 失败: \(error)")
            return
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
            NSLog("[MacShot] 删除属性 \(key) 失败: \(error)")
            return
        }
    }

    // MARK: - 收藏

    func isFavorite(shotID: Int64) -> Bool {
        favoriteIDs.contains(shotID)
    }

    func favoriteCount() -> Int {
        favoriteIDs.count
    }

    func favoritePreviews(limit: Int = 3) -> [Shot] {
        (try? attributeRepository.favoritePreviews(limit: limit)) ?? []
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

    // MARK: - 专题收藏集

    func collectionSummaries() -> [ShotCollectionSummary] {
        (try? collectionRepository.summaries()) ?? []
    }

    func collectionCount() -> Int {
        (try? collectionRepository.count()) ?? 0
    }

    @discardableResult
    func createCollection(name rawName: String, note: String = "") throws -> ShotCollection {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw ShotCollectionError.emptyName }
        let collection = try collectionRepository.create(
            name: name,
            note: note.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        return collection
    }

    func renameCollection(id: Int64, to rawName: String) throws {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw ShotCollectionError.emptyName }
        try collectionRepository.rename(id: id, to: name)
    }

    func deleteCollection(id: Int64) {
        do {
            try collectionRepository.delete(id: id)
        } catch {
            NSLog("[MacShot] 删除收藏集失败: \(error)")
            return
        }
    }

    /// 幂等加入：重复选择同一截图不会制造重复成员。
    func addToCollection(shotIDs: [Int64], collectionID: Int64) throws {
        guard !shotIDs.isEmpty else { return }
        try collectionRepository.add(shotIDs: shotIDs, to: collectionID)
    }

    func removeFromCollection(shotIDs: [Int64], collectionID: Int64) {
        guard !shotIDs.isEmpty else { return }
        do {
            try collectionRepository.remove(shotIDs: shotIDs, from: collectionID)
        } catch {
            NSLog("[MacShot] 移出收藏集失败: \(error)")
            return
        }
    }

    func collectionMemberships(shotIDs: [Int64]) -> [Int64: Set<Int64>] {
        (try? collectionRepository.memberships(shotIDs: shotIDs)) ?? [:]
    }

    // MARK: - 标签
    //
    // `tag` 是**多值 key**（一张图多行），绕开 `writeAttribute` —— 它的
    // default 分支是「同 key 先删后插」的单值语义，走它会把旧标签全冲掉。
    // 这里直接插行 / 按 (shotID, key, text) 精确删行，幂等靠 EXISTS 预查。

    /// 给截图加一个标签。重复添加幂等（先查 EXISTS）；空白名忽略。
    func addTag(shotID: Int64, _ tag: String) {
        let name = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        do {
            try attributeRepository.addTag(shotID: shotID, name: name)
        } catch {
            NSLog("[MacShot] 添加标签 \(name) 失败: \(error)")
            return
        }
    }

    /// 移除截图上的一个标签：按 (shotID, key, text) 精确删行 ——
    /// 现有 `removeAttribute` 按 key 全删，会把其它标签一起带走，不能用。
    func removeTag(shotID: Int64, _ tag: String) {
        do {
            try attributeRepository.removeTag(shotID: shotID, name: tag)
        } catch {
            NSLog("[MacShot] 移除标签 \(tag) 失败: \(error)")
            return
        }
    }

    /// 一张截图的全部标签，按添加顺序。
    func tags(shotID: Int64) -> [String] {
        (try? attributeRepository.tags(shotID: shotID)) ?? []
    }

    /// 现有标签及各自的截图数量，按数量降序。侧边栏和输入建议用。
    func allTags() -> [(name: String, count: Int)] {
        (try? attributeRepository.textCounts(key: AttributeKey.tag)) ?? []
    }

    /// 全局重命名标签。目标名已存在的图先删旧名行再整体 UPDATE，
    /// 避免同图同名出现两行；UPDATE 会触发 attributeFts 的同步触发器，
    /// 全文索引跟着改。侧边栏若正选中旧名，跟着切到新名。
    func renameTag(_ old: String, to new: String) {
        let name = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != old else { return }
        do {
            try attributeRepository.renameTag(old, to: name)
        } catch {
            NSLog("[MacShot] 重命名标签 \(old) 失败: \(error)")
            return
        }
    }

    /// 全局删除标签：只删标签行，截图本身不动。
    /// 侧边栏若正选中该标签，退回「全部」。
    func deleteTag(_ tag: String) {
        do {
            try attributeRepository.deleteTag(tag)
        } catch {
            NSLog("[MacShot] 删除标签 \(tag) 失败: \(error)")
            return
        }
    }

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
        guard shotsToDelete.contains(where: { $0.id != nil }) else { return }

        let orphaned = (try? metadataRepository.delete(shotsToDelete)) ?? []

        for sha in orphaned {
            try? FileManager.default.removeItem(
                at: originalsDirectory.appendingPathComponent("\(sha).png"))
            try? FileManager.default.removeItem(
                at: thumbnailsDirectory.appendingPathComponent("\(sha).jpg"))
        }
    }

    // MARK: - 修订

    func revisions(for shot: Shot) -> [Revision] {
        guard let id = shot.id else { return [] }
        return (try? revisionRepository.revisions(shotID: id)) ?? []
    }

    func latestRevision(for shot: Shot) -> Revision? {
        guard let id = shot.id else { return nil }
        return try? revisionRepository.latestRevision(shotID: id)
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
            let saved = try revisionRepository.append(
                shotID: shotID,
                layers: layers.persisted,
                note: note
            )
            // 缩略图是按**原图**生成、以 sha256 命名的，而 sha 只认原图字节 ——
            // 加多少标注它都不变。不在这里重画的话，图库网格会一直显示没有标注的
            // 那一版（编辑完返回图库「图片没更新」就是这么来的）。
            refreshThumbnail(for: shot, layers: layers)

            // 修订不在 shots 数组里，落库不会自己触发发布 ——
            // 图库网格（缩略图刚换过）、详情栏（历史版本 / 已打码判定）靠这次发布重查。
            objectWillChange.send()
            return saved
        } catch {
            // 此前是 try?，写失败仍返回一个 id 为 nil 的 Revision，调用方无从分辨。
            NSLog("[MacShot] 追加修订失败: \(error)")
            return nil
        }
    }

    // MARK: - 缩略图重画

    /// 把「原图 + 图层」渲染成成品的渲染器。**由 App 层注入**。
    ///
    /// 为什么是闭包而不是直接调 `LayerRenderer`：依赖方向不许 Storage 认识 Render
    /// （ARCHITECTURE §1，Render 在 Storage 之上）。注入点在 `AppDelegate`，
    /// 与其它注册表登记在一起。没注入时（测试、命令行）退化为不重画，行为安全。
    var revisionThumbnailRenderer: ((CGImage, Layers<ImageSpace>) -> CGImage)?

    /// 缩略图换了之后要通知谁把内存缓存里那份旧的丢掉。同样由 App 层注入 ——
    /// 缓存住在 UI 层（`ThumbnailCache`），Storage 更不该认识它。
    var thumbnailInvalidator: ((Shot) -> Void)?

    /// 按当前图层重画缩略图并覆盖写盘。
    ///
    /// 失败一律静默：缩略图是派生数据，画不出来最多是显示旧的一版，
    /// 不该让一次修订保存失败。
    private func refreshThumbnail(for shot: Shot, layers: Layers<ImageSpace>) {
        guard let render = revisionThumbnailRenderer,
              let base = originalImage(for: shot) else { return }

        // ⚠️ **绝不在主线程上跑**。这条链是「全分辨率渲染 → 缩放 → JPEG 编码 → 写盘」，
        // 一张 3456×1986 的截图跑一趟是上百毫秒级；而它挂在自动保存后面，
        // 于是编辑时每隔一秒多就把主线程堵一次 —— 表现为「点按钮有延迟」。
        //
        // CGImage 与 LayerRenderer / ImageCodec 都不是 MainActor 隔离的，
        // 渲染和编码可以整段搬到后台；回主线程的只有一次缓存作废。
        let url = thumbnailURL(for: shot)
        let payload = ThumbnailJob(base: base, layers: layers, render: render, url: url)
        // 作废回调**先取出来**，不要在后台回调里走 `ShotStore.shared` ——
        // 那样非单例的实例（比如测试用的独立库）通知不到自己的订阅方。
        let invalidate = thumbnailInvalidator

        Task.detached(priority: .utility) {
            guard let jpg = payload.encode() else { return }
            try? jpg.write(to: payload.url, options: .atomic)
            await MainActor.run {
                // 文件覆盖了还不够：内存缓存的键是 sha256，而 sha 没变 ——
                // 不主动作废的话界面会继续用缓存里那张旧图。
                invalidate?(shot)
            }
        }
    }

    /// 后台重画缩略图要带走的一整套材料。
    ///
    /// 打包成一个 `@unchecked Sendable` 的值而不是在 `Task.detached` 里逐个捕获：
    /// 这些东西（CGImage、图层数组、渲染闭包）造好之后**没有人再改它们**，
    /// 是一次所有权转移而不是共享。用一个类型把这件事讲明白，
    /// 好过在捕获处埋一串静默的 unchecked。
    private struct ThumbnailJob: @unchecked Sendable {
        let base: CGImage
        let layers: Layers<ImageSpace>
        let render: (CGImage, Layers<ImageSpace>) -> CGImage
        let url: URL

        func encode() -> Data? {
            let composed = render(base, layers)
            guard let thumb = ImageCodec.resized(composed, maxDimension: 640) else { return nil }
            return ImageCodec.jpegData(from: thumb)
        }
    }

    // MARK: - 刷新合并

    /// 两次 reload 之间的最短间隔。写入风暴（启动回填、批量操作）坍缩成 ≤2Hz。
    /// 列表一次最多取多少行。
    ///
    /// 这是一个**临时上限**，不是设计意图：网格目前一次性拿到全部行再交给
    /// `LazyVGrid`，所以行数直接等于内存里的 `Shot` 数组长度。没有它的话，
    /// 十万张的库会在一次 `reload()` 里把十万行取回并解码。
    ///
    /// 真正的解法是**分页**（滚到底再取下一页）：那要连带改网格的滚动、
    /// 分组段头、键盘上下键的步长、以及「全选」的语义（全选是选当前这一页还是全库？），
    /// 所以单独作为一批做。在那之前，超过这个数的老截图仍然搜得到
    /// （搜索走的是同一条 SQL，只是结果也受这个上限约束）。
    ///
    /// 三条列表查询共用这一个常量 —— 此前是三处硬编码的 500，
    /// 改一处漏两处是迟早的事。
    /// `nonisolated`：它被用作 `allShots(limit:)` 的默认参数，
    /// 而默认参数在调用方的上下文里求值，可能不是主 actor。
    /// 一页多少行。
    ///
    /// 取 300：足够铺满几屏（默认缩放下一屏约 20 张），滚动时不会频繁触发下一页；
    /// 又远小于「整库」，所以第一屏的等待与库的大小无关 —— 这正是分页的意义。
    nonisolated static let pageSize = 300

    /// 已经没有下一页了。滚到底的触发器据此停手，UI 也据此决定要不要显示加载中。
    private(set) var hasMorePages = false

    /// 下一页的游标 = 当前已加载的最后一行。nil 表示还没加载过。
    private var pageCursor: ShotQueryRepository.PageCursor? {
        shots.last.flatMap { shot in
            shot.id.map { ShotQueryRepository.PageCursor(capturedAt: shot.capturedAt, id: $0) }
        }
    }

    /// 正在取下一页 —— 防止滚动触发器在同一页上重复发起。
    private var isLoadingPage = false

    // MARK: - 查询

    /// 按明确的图库查询条件同步刷新。查询条件由 `GalleryViewModel` 持有；
    /// Store 只保留这份缓存来源快照，供后续写入刷新和翻页复用。
    func reload(query rawQuery: String, filter: ShotFilter) {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        restartLibraryObservation(
            request: ActiveListQuery(text: query, filter: filter),
            immediately: true
        )
    }

    /// 刷新当前缓存对应的查询。库存写入后的自动刷新与定位类调用使用。
    func reload() {
        reload(query: activeListQuery.text, filter: activeListQuery.filter)
    }

    /// 异步建立同一份持续观察，并等待首个快照发布。后续数据库提交继续由该观察驱动。
    func reloadInBackground(query rawQuery: String, filter: ShotFilter) async {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let request = ActiveListQuery(text: query, filter: filter)
        await withCheckedContinuation { continuation in
            restartLibraryObservation(
                request: request,
                immediately: false,
                onInitial: { continuation.resume() }
            )
        }
    }

    /// 异步重建当前缓存对应的观察。
    func reloadInBackground() async {
        let request = activeListQuery
        await reloadInBackground(query: request.text, filter: request.filter)
    }

    private func restartLibraryObservation(
        request: ActiveListQuery,
        immediately: Bool,
        onInitial: (() -> Void)? = nil
    ) {
        finishPendingInitialObservation()
        listObservation?.cancel()
        listObservationGeneration += 1
        let generation = listObservationGeneration
        activeListQuery = request
        pendingInitialObservation = onInitial

        listObservation = queryRepository.observeLibrary(
            query: request.text,
            filter: request.filter,
            limit: Self.pageSize,
            immediately: immediately,
            onError: { [weak self] error in
                guard let self,
                      generation == self.listObservationGeneration,
                      request == self.activeListQuery
                else { return }
                NSLog("[MacShot] 图库数据库观察失败: \(error)")
                self.finishPendingInitialObservation()
            },
            onChange: { [weak self] snapshot in
                guard let self,
                      generation == self.listObservationGeneration,
                      request == self.activeListQuery
                else { return }
                self.publish(shots: snapshot.shots, favorites: snapshot.favoriteIDs)
                self.finishPendingInitialObservation()
            }
        )
    }

    private func finishPendingInitialObservation() {
        let completion = pendingInitialObservation
        pendingInitialObservation = nil
        completion?()
    }

    /// 赋值 + 发通知。数据库观察的每个有效快照只走这一条发布路径。
    ///
    /// 先算好再一起赋值，整轮刷新只发一次 `objectWillChange` ——
    /// 此前 shots / favoriteIDs 两个 @Published 各发一次，订阅方级联重查两遍。
    private func publish(shots newShots: [Shot], favorites newFavoriteIDs: Set<Int64>) {
        objectWillChange.send()
        shots = newShots
        favoriteIDs = newFavoriteIDs
        // 取满一页就假定还有下一页。这会导致「总数正好是页大小整数倍」时
        // 多翻一次空页 —— 代价是一次查询，换来的是不必每轮刷新都跑一条 COUNT(*)。
        hasMorePages = newShots.count >= Self.pageSize
        libraryDidChange.send()
    }

    /// 取下一页并追加。滚到底时由网格触发。
    ///
    /// 没有下一页、正在取、或者当前是语义搜索结果（那是一次性的完整排序，
    /// 不分页）时都直接返回 —— 触发器可以放心地多调。
    func loadNextPage() async {
        guard hasMorePages, !isLoadingPage else { return }
        guard let cursor = pageCursor else { return }

        isLoadingPage = true
        defer { isLoadingPage = false }

        let request = activeListQuery
        let page = (try? await queryRepository.shotsInBackground(
            query: request.text,
            filter: request.filter,
            after: cursor,
            limit: Self.pageSize
        )) ?? []

        // 翻页途中筛选/搜索被改过：这一页属于旧条件，丢掉。
        // （`reload` 会把 shots 换成新条件的第一页，此时游标也已经不是我们那个。）
        guard cursor == pageCursor, activeListQuery == request else { return }

        objectWillChange.send()
        shots.append(contentsOf: page)
        hasMorePages = page.count >= Self.pageSize
        // **不发 `libraryDidChange`**：库存内容没变，只是多显示了一段。
        // 发了会让胶片条无谓地重查全库（那条信号的由来见它的注释）。
    }

    /// 当前筛选 / 搜索下的**全部** ID，不受分页限制。
    ///
    /// 「全选」要的是「符合当前条件的所有截图」，而不是「已经滚出来的那些」——
    /// 后者会让同一个 ⌘A 因为你滚了多远而选中不同的东西。
    /// 只取 id 一列，十万行也就几百 KB。
    func allMatchingIDs(query rawQuery: String, filter: ShotFilter) async -> [Int64] {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        // 复用同一份查询体（共用 SQL 那条纪律），只是不限量、只要 id。
        let all = (try? await queryRepository.shotsInBackground(
            query: query,
            filter: filter,
            limit: Int.max
        )) ?? []
        return all.compactMap(\.id)
    }

    /// 语义搜索的候选范围只看固定筛选，不把自然语言查询误当成精确文本查询。
    /// 复用 `ShotQueryRepository` 的筛选 SQL，避免录屏 / 标签 / App 各写一套条件。
    func matchingShotIDsInBackground(filter: ShotFilter) async -> Set<Int64> {
        let rows = (try? await queryRepository.shotsInBackground(
            query: "",
            filter: filter,
            limit: Int.max
        )) ?? []
        return Set(rows.compactMap(\.id))
    }

    /// 「库存内容变了」——新增 / 删除 / 筛选重查，即每次 `reload()`。
    ///
    /// 与 `objectWillChange` 的区别很关键：后者**任何**写入都会发，包括
    /// 「给某张图追加一条修订」这种不改变库存的操作。订阅方如果只关心
    /// 「有哪些截图」，订 `objectWillChange` 就会被修订保存反复惊动 ——
    /// 编辑器胶片条正是这样每隔一秒多在主线程上重查一次全库（500 行取回 + 全量解码），
    /// 表现为编辑时点按钮有延迟。
    let libraryDidChange = PassthroughSubject<Void, Never>()

    var totalCount: Int {
        (try? metadataRepository.count()) ?? 0
    }

    // MARK: - 智能筛选：时间边界与计数
    //
    // 侧边栏的四个徽章会在**每轮 store 变更后**一起重算，所以这四个查询
    // 必须各是一条聚合 SQL —— 把行取回来再在 Swift 里 count（`relatedShots`
    // 那种全表拉取）在这个调用频率下是不可接受的。

    /// 一个标签都没打过的截图数。侧边栏徽章用。
    ///
    /// `NOT EXISTS` 相关子查询走 (shotID, key) 复合索引，每张图一次索引探测；
    /// `LEFT JOIN … IS NULL` 在多值 tag 下还要额外去重，这里不用它。
    func untaggedCount() -> Int {
        (try? queryRepository.untaggedCount()) ?? 0
    }

    /// 真的标注过的截图数。侧边栏徽章用。
    ///
    /// 口径与卡片铅笔角标（`annotatedShotIDs`）、清理豁免（`cleanupCandidates`）
    /// 三处统一：修订数 > 1，即除了入库时自动建的那条「原始」空修订之外还有别的。
    /// 分组走 revision.shotID 索引，外层只数分组数，不取行。
    func annotatedCount() -> Int {
        (try? revisionRepository.annotatedCount()) ?? 0
    }

    /// 全库时间倒序，**不受** `GalleryViewModel` 查询条件影响（`shots` 是筛选后的列表）。
    /// 编辑器胶片条用：换图的心智是「库里最近截了什么」，不跟图库窗口的筛选联动。
    /// 胶片条是**横向一条**、只用来跳到最近的图，不做分页 ——
    /// 取一页的量就够，再多也滚不过来。
    func allShots(limit: Int = ShotStore.pageSize) -> [Shot] {
        (try? metadataRepository.recent(limit: limit)) ?? []
    }

    /// 记录是否还在库里。编辑器窗口用它在库变更后判断「正在编辑的 shot 被删了」。
    func shotExists(id: Int64) -> Bool {
        (try? metadataRepository.exists(id: id)) ?? false
    }

    /// 应用首页的完整聚合：稳定身份、数量、最近捕获时间和最新三张预览。
    /// 单条窗口查询只返回每个 App 最新三行，不把整库截图拉回主线程。
    func capturedApps() -> [CapturedAppSummary] {
        (try? metadataRepository.capturedApps()) ?? []
    }

    /// 现有分类及各自的截图数量，按数量降序。图库侧边栏用。
    func categories() -> [(name: String, count: Int)] {
        (try? attributeRepository.textCounts(key: AttributeKey.category)) ?? []
    }

    /// 读一条派生属性的文本值。详情页展示分类 / 标签用。
    func attributeText(shotID: Int64, key: String) -> String? {
        try? attributeRepository.text(shotID: shotID, key: key)
    }

    /// 批量读一批截图的某个文本属性。图库网格给卡片配分类胶囊用 ——
    /// 逐卡片查一次库会在滚动时反复打主线程，这里一条 IN 查询拉全量。
    func attributeTexts(key: String, shotIDs: [Int64]) -> [Int64: String] {
        (try? attributeRepository.texts(key: key, shotIDs: shotIDs)) ?? [:]
    }

    /// 一批截图里「真的标注过」（修订数 > 1，超出入库时自动建的那条「原始」）
    /// 的 ID 集合。图库网格的标注角标用，一条聚合查询。
    func annotatedShotIDs(among shotIDs: [Int64]) -> Set<Int64> {
        (try? revisionRepository.annotatedShotIDs(among: shotIDs)) ?? []
    }

    /// 读一条派生属性的二进制载荷。相似检索取目标指纹用。
    func attributePayload(shotID: Int64, key: String) -> Data? {
        try? attributeRepository.payload(shotID: shotID, key: key)
    }

    /// 某个 key 的全部二进制载荷（shotID + payload）。相似检索的候选集，一条 SQL 拉全量。
    func attributePayloads(key: String) -> [(shotID: Int64, payload: Data)] {
        (try? attributeRepository.payloads(key: key)) ?? []
    }

    /// 同上，但**在后台连接上读**。
    ///
    /// 这是相似图 / 语义搜索的入口：一次要把全库的特征向量取回来
    /// （CLIP 512 维约 2KB/张，指纹更大），几千张就是几十 MB 的 blob。
    /// 同步版本会把这几十 MB 的取回与解码全压在主线程上 —— 点一次「查找相似」
    /// 就卡一下。`DatabasePool` 的读连接与写连接互不阻塞（WAL），
    /// 所以这一趟完全不必占用主线程。
    nonisolated func attributePayloadsInBackground(
        key: String
    ) async -> [(shotID: Int64, payload: Data)] {
        (try? await attributeRepository.payloadsInBackground(key: key)) ?? []
    }

    /// 与目标视觉最相似的截图，按特征指纹距离升序取前 `limit` 张。
    ///
    /// 线程边界：目标载荷同步读取，候选载荷通过属性仓储的后台连接拉出，
    /// 反序列化和距离计算这类 CPU 活挪到后台，算完回主 actor 按 ID 取 Shot。
    /// 全量线性扫描 —— 两千张以内毫无压力，更大的库需要上向量索引再优化。
    func similarShots(to shot: Shot, limit: Int = 12) async -> [Shot] {
        guard let targetID = shot.id,
              let targetData = attributePayload(shotID: targetID, key: AttributeKey.featurePrint)
        else { return [] }

        // 后台取 blob：几千张时这是几十 MB，同步读会把主线程按住。
        let candidates = await attributePayloadsInBackground(key: AttributeKey.featurePrint)
            .filter { $0.shotID != targetID }
        guard !candidates.isEmpty else { return [] }

        let rankedIDs = await Task.detached(priority: .userInitiated) { () -> [Int64] in
            guard let target = FeaturePrint.observation(from: targetData) else { return [] }
            var scored: [(shotID: Int64, distance: Float)] = []
            scored.reserveCapacity(candidates.count)
            for candidate in candidates {
                // 解档失败或指纹版本不兼容的直接跳过。
                guard let observation = FeaturePrint.observation(from: candidate.payload),
                      let distance = FeaturePrint.distance(target, to: observation)
                else { continue }
                scored.append((candidate.shotID, distance))
            }
            return scored
                .sorted { $0.distance < $1.distance }
                .prefix(limit)
                .map(\.shotID)
        }.value
        guard !rankedIDs.isEmpty else { return [] }

        let fetched = shots(ids: rankedIDs)
        let byID = Dictionary(uniqueKeysWithValues: fetched.compactMap { s in s.id.map { ($0, s) } })
        // IN 查询不保序，按距离升序重排。
        return rankedIDs.compactMap { byID[$0] }
    }

    // MARK: - 同源时间线

    /// 归一化网址用于同源判定：去掉 fragment、去掉尾部斜杠。
    /// 「同一页面」的语义下 `…/docs#intro` 和 `…/docs/` 都算 `…/docs`。
    static func normalizedSourceURL(_ raw: String) -> String {
        var s = raw
        if let hash = s.firstIndex(of: "#") {
            s = String(s[..<hash])
        }
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    /// 与目标同源的截图序列（**含自己**），按拍摄时间升序。判定优先级：
    ///
    /// 1. 有网址 → 归一化后相同（同一页面的演化史）
    /// 2. 否则有 bundleID + 窗口标题 → 两者都相同（同一 App 窗口）
    /// 3. 否则只有 bundleID → 同一 App
    ///
    /// 少于 2 张视为无同源，调用方据此禁用入口。
    /// 网址匹配需要归一化，SQL 表达不了，取回候选后在 Swift 里过滤 —— 数据量小，不值得更聪明。
    func relatedShots(to shot: Shot) -> [Shot] {
        if let source = shot.sourceURL {
            let target = Self.normalizedSourceURL(source)
            // 先在 SQL 里用前缀把候选缩到一小撮，再在 Swift 里做精确判定。
            //
            // 能这么做是因为归一化只**截短**（去掉 `#锚点`、去掉末尾斜杠）——
            // 归一化后的串必然是原串的前缀，所以「归一化后等于 target」的行
            // 一定满足 `sourceURL LIKE 'target%'`。反过来不成立（比如
            // target 是 `…/a`，`…/abc` 也会命中前缀），所以后面那次精确过滤不能省。
            //
            // 此前这里是 `sourceURL IS NOT NULL` —— **把全库带网址的行整个取回来**
            // 再在 Swift 里筛，而它挂在详情栏上，每选一张卡片就跑一次。
            // 几千张浏览器截图时这是明显的卡顿源（审计记录在案的重灾区）。
            let candidates = (try? metadataRepository.relatedBySourcePrefix(target)) ?? []
            return candidates
                .filter { $0.sourceURL.map(Self.normalizedSourceURL) == target }
        }
        if let bundleID = shot.appBundleID {
            return (try? metadataRepository.related(
                bundleID: bundleID,
                windowTitle: shot.windowTitle
            )) ?? []
        }
        return []
    }

    // MARK: - 语义搜索

    /// 按自然语言描述搜截图：查询文本过 CLIP 文本编码器，
    /// 与全部图像向量算余弦相似度（向量已归一化，等于点积），降序取前 `limit` 张。
    ///
    /// 线程边界与 `similarShots` 相同：候选载荷在主 actor 上一次性拉出，
    /// 反序列化和点积挪到后台，算完回主 actor 按 ID 取 Shot。
    /// 全量线性扫描，512 维 × 几千张在毫秒量级。
    func semanticSearch(
        query: String,
        limit: Int = 30,
        filter: ShotFilter = .all
    ) async -> [Shot] {
        guard let queryVector = await CLIPEncoder.shared.embedText(query) else { return [] }

        // 固定 destination / 普通筛选都必须约束候选集。先用共用筛选 SQL 得到
        // 允许 ID，再从后台取回的向量中求交；不能先取全库 top 30 再过滤，
        // 否则录屏较少时会错误地得到空结果。
        let allowedIDs: Set<Int64>?
        if filter == .all {
            allowedIDs = nil
        } else {
            allowedIDs = await matchingShotIDsInBackground(filter: filter)
        }
        let allCandidates = await attributePayloadsInBackground(key: AttributeKey.clipEmbedding)
        let candidates = allowedIDs.map { allowed in
            allCandidates.filter { allowed.contains($0.shotID) }
        } ?? allCandidates
        guard !candidates.isEmpty else { return [] }

        let rankedIDs = await Task.detached(priority: .userInitiated) { () -> [Int64] in
            var scored: [(shotID: Int64, similarity: Float)] = []
            scored.reserveCapacity(candidates.count)
            for candidate in candidates {
                // 载荷损坏或维度不匹配（未来换模型）的直接跳过。
                guard let vector = CLIPEncoder.vector(from: candidate.payload),
                      vector.count == queryVector.count
                else { continue }
                scored.append((candidate.shotID, CLIPEncoder.dot(queryVector, vector)))
            }
            return scored
                .sorted { $0.similarity > $1.similarity }
                .prefix(limit)
                .map(\.shotID)
        }.value
        guard !rankedIDs.isEmpty else { return [] }

        let fetched = shots(ids: rankedIDs)
        let byID = Dictionary(uniqueKeysWithValues: fetched.compactMap { s in s.id.map { ($0, s) } })
        // IN 查询不保序，按相似度降序重排。
        return rankedIDs.compactMap { byID[$0] }
    }

    /// 按 ID 批量取 Shot。同步方法，避免在 async 上下文里误触 GRDB 的 async read 重载。
    private func shots(ids: [Int64]) -> [Shot] {
        (try? metadataRepository.shots(ids: ids)) ?? []
    }

    /// 自动清理的候选：拍摄早于 `cutoff`、未收藏、没加入专题集、没打过标签、
    /// 没有原始附件，且从未标注过。
    ///
    /// 「从未标注过」= 修订数 ≤ 1，即只有入库时自动建的那条「原始」空修订 ——
    /// 截图时标注、钉图上画、编辑器里改，任何一笔都会追加修订、让计数超过 1，
    /// 从而永久脱离清理范围。打过标签同理豁免 —— 用户亲手组织过的图，
    /// 就是在说「我在意它」。按时间升序：一批删不完时先删最老的，剩下的留给下次。
    func cleanupCandidates(olderThan cutoff: Date, limit: Int) -> [Shot] {
        (try? queryRepository.cleanupCandidates(olderThan: cutoff, limit: limit)) ?? []
    }

    /// 还没有指定 key 属性的截图。启动回填用。
    func shotsMissingAttribute(key: String) -> [Shot] {
        (try? attributeRepository.shotsMissing(key: key)) ?? []
    }

    enum StoreError: Error {
        case encodingFailed
        case missingShotID
    }

}
