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
    @Published var searchText: String = ""
    /// 分类筛选。nil 表示「全部」。
    /// 图库侧边栏选中的筛选维度。
    enum GalleryFilter: Hashable {
        case all
        case favorites
        /// 一个 `tag` 属性行都没有的截图 —— 「想整理时从这里开始」。
        case untagged
        /// 真的画过标注的截图。口径与卡片右下角的铅笔角标
        /// （`annotatedShotIDs`）完全一致：修订数 > 1。
        case annotated
        case category(String)
        case tag(String)
        /// 按来源 App。侧边栏的主线索（见 `AppsSidebarSection`）。
        case app(String)

        // 曾经还有 `today` / `thisWeek` 两个 case，随侧边栏简化一起删了：
        // 网格本来就按日期分组、最新在最上，「今天」等于滚到顶。
        //
        // `favorites` / `untagged` / `annotated` / `category` / `tag` 目前
        // **没有对应的侧边栏分区**（那几组按用户要求撤掉了），但保留着 ——
        // 它们各自的分区是计划中的下一批，届时只需加一个 `SidebarSection` 实现。
    }

    @Published var filter: GalleryFilter = .all

    /// 图库搜索模式：false = 精确（FTS），true = 语义（CLIP 向量）。
    @Published var semanticMode = false
    /// 语义搜索结果。nil = 还没搜过（网格显示 shots），非 nil = 显示它。
    @Published private(set) var semanticResults: [Shot]?
    /// 语义搜索进行中（文本编码 + 全库比对），UI 显示进度用。
    @Published private(set) var isSemanticSearching = false

    /// 图库网格实际展示的内容。语义模式下已出结果就用结果，否则退回常规列表。
    var displayShots: [Shot] {
        semanticMode ? (semanticResults ?? shots) : shots
    }

    /// 收藏的截图 ID。随 reload() 一起刷新，UI 直接读集合，不逐卡片查库。
    /// 不是 @Published，理由同 `shots`。
    private(set) var favoriteIDs: Set<Int64> = []

    let rootDirectory: URL
    let originalsDirectory: URL
    let thumbnailsDirectory: URL

    /// 数据库连接。类型是 `any DatabaseWriter` 而不是具体类型 ——
    /// 生产用 `DatabasePool`（多读连接 + WAL），测试用内存 `DatabaseQueue`。
    ///
    /// **它本身不是 MainActor 隔离的**，所以可以安全地在后台读：
    /// `dbQueue.read {}` 的闭包跑在 GRDB 自己的读连接上，与主线程无关。
    /// 这是把重查询挪出主线程的通路（见 `readInBackground`）。
    private let dbQueue: any DatabaseWriter

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

        if let database {
            dbQueue = database
        } else {
            do {
                dbQueue = try AppDatabase.makeWriter(at: base.appendingPathComponent("index.sqlite"))
            } catch {
                fatalError("无法打开数据库: \(error)")
            }
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

        setNeedsReload()
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
        setNeedsReload()
    }

    /// 删除一条派生属性。取消收藏这类「有即为真」的标记需要真正删除记录，
    /// 而不是写一个空值 —— 筛选和计数都靠 EXISTS 判断。
    func removeAttribute(shotID: Int64, key: String) {
        do {
            try dbQueue.write { db in
                _ = try ShotAttribute
                    .filter(Column("shotID") == shotID && Column("key") == key)
                    .deleteAll(db)
            }
        } catch {
            NSLog("[MacShot] 删除属性 \(key) 失败: \(error)")
            return
        }
        setNeedsReload()
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
            try dbQueue.write { db in
                let exists = try Bool.fetchOne(db, sql: """
                    SELECT EXISTS (
                        SELECT 1 FROM shotAttribute
                        WHERE shotID = ? AND key = ? AND text = ?
                    )
                    """, arguments: [shotID, AttributeKey.tag, name]) ?? false
                guard !exists else { return }
                var record = ShotAttribute(
                    id: nil,
                    shotID: shotID,
                    key: AttributeKey.tag,
                    text: name,
                    payload: nil,
                    createdAt: Date()
                )
                try record.insert(db)
            }
        } catch {
            NSLog("[MacShot] 添加标签 \(name) 失败: \(error)")
            return
        }
        setNeedsReload()
    }

    /// 移除截图上的一个标签：按 (shotID, key, text) 精确删行 ——
    /// 现有 `removeAttribute` 按 key 全删，会把其它标签一起带走，不能用。
    func removeTag(shotID: Int64, _ tag: String) {
        do {
            try dbQueue.write { db in
                _ = try ShotAttribute
                    .filter(
                        Column("shotID") == shotID
                            && Column("key") == AttributeKey.tag
                            && Column("text") == tag
                    )
                    .deleteAll(db)
            }
        } catch {
            NSLog("[MacShot] 移除标签 \(tag) 失败: \(error)")
            return
        }
        setNeedsReload()
    }

    /// 一张截图的全部标签，按添加顺序。
    func tags(shotID: Int64) -> [String] {
        (try? dbQueue.read { db in
            try String.fetchAll(db, sql: """
                SELECT text FROM shotAttribute
                WHERE shotID = ? AND key = ? AND text IS NOT NULL
                ORDER BY id ASC
                """, arguments: [shotID, AttributeKey.tag])
        }) ?? []
    }

    /// 现有标签及各自的截图数量，按数量降序。侧边栏和输入建议用。
    func allTags() -> [(name: String, count: Int)] {
        (try? dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT text AS name, COUNT(*) AS count FROM shotAttribute
                WHERE key = ? AND text IS NOT NULL
                GROUP BY text
                ORDER BY count DESC, name ASC
                """, arguments: [AttributeKey.tag])
                .map { (name: $0["name"] as String, count: $0["count"] as Int) }
        }) ?? []
    }

    /// 全局重命名标签。目标名已存在的图先删旧名行再整体 UPDATE，
    /// 避免同图同名出现两行；UPDATE 会触发 attributeFts 的同步触发器，
    /// 全文索引跟着改。侧边栏若正选中旧名，跟着切到新名。
    func renameTag(_ old: String, to new: String) {
        let name = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != old else { return }
        do {
            try dbQueue.write { db in
                try db.execute(sql: """
                    DELETE FROM shotAttribute
                    WHERE key = :key AND text = :old AND shotID IN (
                        SELECT shotID FROM shotAttribute WHERE key = :key AND text = :new
                    )
                    """, arguments: ["key": AttributeKey.tag, "old": old, "new": name])
                try db.execute(sql: """
                    UPDATE shotAttribute SET text = :new WHERE key = :key AND text = :old
                    """, arguments: ["key": AttributeKey.tag, "old": old, "new": name])
            }
        } catch {
            NSLog("[MacShot] 重命名标签 \(old) 失败: \(error)")
            return
        }
        if filter == .tag(old) { filter = .tag(name) }
        setNeedsReload()
    }

    /// 全局删除标签：只删标签行，截图本身不动。
    /// 侧边栏若正选中该标签，退回「全部」。
    func deleteTag(_ tag: String) {
        do {
            try dbQueue.write { db in
                _ = try ShotAttribute
                    .filter(Column("key") == AttributeKey.tag && Column("text") == tag)
                    .deleteAll(db)
            }
        } catch {
            NSLog("[MacShot] 删除标签 \(tag) 失败: \(error)")
            return
        }
        if filter == .tag(tag) { filter = .all }
        setNeedsReload()
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
        let ids = shotsToDelete.compactMap(\.id)
        guard !ids.isEmpty else { return }
        let shas = Set(shotsToDelete.filter { $0.id != nil }.map(\.sha256))

        let orphaned: Set<String> = (try? dbQueue.write { db -> Set<String> in
            try Shot.filter(ids.contains(Column("id"))).deleteAll(db)
            let stillReferenced = try Shot
                .select(Column("sha256"), as: String.self)
                .filter(shas.contains(Column("sha256")))
                .distinct()
                .fetchAll(db)
            return shas.subtracting(stillReferenced)
        }) ?? []

        for sha in orphaned {
            try? FileManager.default.removeItem(
                at: originalsDirectory.appendingPathComponent("\(sha).png"))
            try? FileManager.default.removeItem(
                at: thumbnailsDirectory.appendingPathComponent("\(sha).jpg"))
        }
        setNeedsReload()
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
            let saved = try dbQueue.write { db -> Revision in
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
    nonisolated static let listFetchLimit = 2000

    private static let reloadInterval: TimeInterval = 0.5
    private var lastReloadAt: Date = .distantPast
    private var pendingReload: Task<Void, Never>?

    /// 写路径统一走这里，leading + trailing 节流：
    /// 距上次 reload 超过 `reloadInterval` 就立即执行（用户单次操作零延迟），
    /// 否则安排一次 trailing 合并执行 —— 密集写入合并成一轮全量刷新。
    /// 需要立即语义的外部调用方（如 `GalleryWindowController.show`）继续用 `reload()`。
    private func setNeedsReload() {
        guard pendingReload == nil else { return }
        let elapsed = Date().timeIntervalSince(lastReloadAt)
        if elapsed >= Self.reloadInterval {
            reload()
            return
        }
        let delay = Self.reloadInterval - elapsed
        // 一次性 Task 而非常驻 Timer：没有积压时不存在任何调度物。
        pendingReload = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch {
                return // 被中途的立即 reload() 取消，那次已经刷过了。
            }
            guard let self else { return }
            self.pendingReload = nil
            self.reload()
        }
    }

    // MARK: - 查询

    func reload() {
        pendingReload?.cancel()
        pendingReload = nil
        lastReloadAt = Date()

        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let filter = filter
        let newShots = (try? dbQueue.read { db -> [Shot] in
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
            // ⚠️ 技术债：本文件里 `.favorites` / `.category` 以及 `cleanupCandidates`
            // 的 SQL 仍写着 'favorite' / 'category' / 'tag' 裸字符串，与
            // `AttributeKey` 常量脱钩（2026-07 审计记录在案）。新增查询一律改用
            // 绑定参数传常量，不再制造新的裸串。
            // NOT EXISTS 命中 v4 建的 (shotID, key) 复合索引。
            case .untagged:
                filterClause = """
                    AND NOT EXISTS (
                        SELECT 1 FROM shotAttribute
                        WHERE shotID = shot.id AND key = :tagKey
                    )
                    """
                arguments["tagKey"] = AttributeKey.tag
            case .annotated:
                filterClause = """
                    AND shot.id IN (
                        SELECT shotID FROM revision GROUP BY shotID HAVING COUNT(*) > 1
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
            case .tag(let name):
                filterClause = """
                    AND EXISTS (
                        SELECT 1 FROM shotAttribute
                        WHERE shotID = shot.id AND key = 'tag' AND text = :filterValue
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
                    LIMIT \(Self.listFetchLimit)
                    """, arguments: StatementArguments(arguments))
            }
            // ⚠️ **trigram 分词器搜不了少于 3 个字符的词**（SQLite 的既定行为：
            // 索引的是三字符片段，两字符的 MATCH 永远返回空）。中文里两字词是绝对
            // 主力 —— 文档、报告、终端、代码、微信……全都搜不到，实测「文档」在库里
            // 有 5 张却 0 命中。所以短查询绕开 FTS，改用 LIKE 全表子串扫。
            //
            // 只有短查询走 LIKE：长查询继续吃 FTS 的索引，不牺牲大库的速度。
            // LIKE 扫的列与两张 FTS 虚表建表时的列一一对应，两条路径的可搜范围一致。
            if query.count < 3 {
                // `%` `_` 是 LIKE 的通配符，用户搜它们时得转义，否则「50%」会变成万能匹配。
                let escaped = query
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "%", with: "\\%")
                    .replacingOccurrences(of: "_", with: "\\_")
                arguments["like"] = "%\(escaped)%"
                return try Shot.fetchAll(db, sql: """
                    SELECT shot.* FROM shot
                    WHERE (
                        shot.appName LIKE :like ESCAPE '\\'
                        OR shot.windowTitle LIKE :like ESCAPE '\\'
                        OR shot.sourceURL LIKE :like ESCAPE '\\'
                        OR shot.ocrText LIKE :like ESCAPE '\\'
                        OR shot.id IN (
                            SELECT shotID FROM shotAttribute
                            WHERE text LIKE :like ESCAPE '\\'
                        )
                    ) \(filterClause)
                    ORDER BY shot.capturedAt DESC
                    LIMIT \(Self.listFetchLimit)
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
                LIMIT \(Self.listFetchLimit)
                """, arguments: StatementArguments(arguments))
        }) ?? []

        let newFavoriteIDs = Set((try? dbQueue.read { db in
            try Int64.fetchAll(db, sql: """
                SELECT shotID FROM shotAttribute WHERE key = 'favorite'
                """)
        }) ?? [])

        // 先算好再一起赋值，整轮 reload 只发一次 objectWillChange ——
        // 此前 shots / favoriteIDs 两个 @Published 各发一次，订阅方级联重查两遍。
        objectWillChange.send()
        shots = newShots
        favoriteIDs = newFavoriteIDs
        libraryDidChange.send()
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
        (try? dbQueue.read { db in try Shot.fetchCount(db) }) ?? 0
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
        (try? dbQueue.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM shot
                WHERE NOT EXISTS (
                    SELECT 1 FROM shotAttribute
                    WHERE shotAttribute.shotID = shot.id AND shotAttribute.key = ?
                )
                """, arguments: [AttributeKey.tag]) ?? 0
        }) ?? 0
    }

    /// 真的标注过的截图数。侧边栏徽章用。
    ///
    /// 口径与卡片铅笔角标（`annotatedShotIDs`）、清理豁免（`cleanupCandidates`）
    /// 三处统一：修订数 > 1，即除了入库时自动建的那条「原始」空修订之外还有别的。
    /// 分组走 revision.shotID 索引，外层只数分组数，不取行。
    func annotatedCount() -> Int {
        (try? dbQueue.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM (
                    SELECT shotID FROM revision GROUP BY shotID HAVING COUNT(*) > 1
                )
                """) ?? 0
        }) ?? 0
    }

    /// 全库时间倒序，**不受** `searchText` / `filter` 影响（`shots` 是筛选后的列表）。
    /// 编辑器胶片条用：换图的心智是「库里最近截了什么」，不跟图库窗口的筛选联动。
    /// 上限与图库一致（500），避免超大库一次性拉全表。
    func allShots(limit: Int = ShotStore.listFetchLimit) -> [Shot] {
        (try? dbQueue.read { db in
            try Shot.fetchAll(db, sql: """
                SELECT * FROM shot ORDER BY capturedAt DESC LIMIT ?
                """, arguments: [limit])
        }) ?? []
    }

    /// 记录是否还在库里。编辑器窗口用它在库变更后判断「正在编辑的 shot 被删了」。
    func shotExists(id: Int64) -> Bool {
        (try? dbQueue.read { db in
            try Shot.filter(key: id).fetchCount(db) > 0
        }) ?? false
    }

    /// 截图来源 App 及数量，按数量降序。侧边栏「应用」分区用；
    /// bundleID 用来取真实 App 图标（`MAX()` 只是为了在 GROUP BY 下取到一个值，
    /// 同名 App 的 bundleID 实际上是一致的）。
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

    /// 读一条派生属性的文本值。详情页展示分类 / 标签用。
    func attributeText(shotID: Int64, key: String) -> String? {
        try? dbQueue.read { db in
            try String.fetchOne(db, sql: """
                SELECT text FROM shotAttribute WHERE shotID = ? AND key = ? LIMIT 1
                """, arguments: [shotID, key])
        }
    }

    /// 批量读一批截图的某个文本属性。图库网格给卡片配分类胶囊用 ——
    /// 逐卡片查一次库会在滚动时反复打主线程，这里一条 IN 查询拉全量。
    func attributeTexts(key: String, shotIDs: [Int64]) -> [Int64: String] {
        guard !shotIDs.isEmpty else { return [:] }
        let rows = (try? dbQueue.read { db in
            try ShotAttribute
                .filter(Column("key") == key && shotIDs.contains(Column("shotID")))
                .fetchAll(db)
        }) ?? []
        var result: [Int64: String] = [:]
        for row in rows {
            if let text = row.text { result[row.shotID] = text }
        }
        return result
    }

    /// 一批截图里「真的标注过」（修订数 > 1，超出入库时自动建的那条「原始」）
    /// 的 ID 集合。图库网格的标注角标用，一条聚合查询。
    func annotatedShotIDs(among shotIDs: [Int64]) -> Set<Int64> {
        guard !shotIDs.isEmpty else { return [] }
        let idList = shotIDs.map(String.init).joined(separator: ",")
        return Set((try? dbQueue.read { db in
            try Int64.fetchAll(db, sql: """
                SELECT shotID FROM revision
                WHERE shotID IN (\(idList))
                GROUP BY shotID
                HAVING COUNT(*) > 1
                """)
        }) ?? [])
    }

    /// 读一条派生属性的二进制载荷。相似检索取目标指纹用。
    func attributePayload(shotID: Int64, key: String) -> Data? {
        try? dbQueue.read { db in
            try Data.fetchOne(db, sql: """
                SELECT payload FROM shotAttribute
                WHERE shotID = ? AND key = ? AND payload IS NOT NULL LIMIT 1
                """, arguments: [shotID, key])
        }
    }

    /// 某个 key 的全部二进制载荷（shotID + payload）。相似检索的候选集，一条 SQL 拉全量。
    func attributePayloads(key: String) -> [(shotID: Int64, payload: Data)] {
        (try? dbQueue.read { db in
            try Self.fetchPayloads(db, key: key)
        }) ?? []
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
        (try? await dbQueue.read { db in
            try Self.fetchPayloads(db, key: key)
        }) ?? []
    }

    /// 两个版本共用的取数实现 —— SQL 只该有一份。
    private nonisolated static func fetchPayloads(
        _ db: Database, key: String
    ) throws -> [(shotID: Int64, payload: Data)] {
        try Row.fetchAll(db, sql: """
            SELECT shotID, payload FROM shotAttribute
            WHERE key = ? AND payload IS NOT NULL
            """, arguments: [key]).map {
                (shotID: $0["shotID"] as Int64, payload: $0["payload"] as Data)
            }
    }

    /// 与目标视觉最相似的截图，按特征指纹距离升序取前 `limit` 张。
    ///
    /// 线程边界：候选载荷在主 actor 上一次性拉出（dbQueue 的调用约定不变），
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
        func fetch(_ predicate: SQLSpecificExpressible) -> [Shot] {
            (try? dbQueue.read { db in
                try Shot
                    .filter(predicate)
                    .order(Column("capturedAt").asc, Column("id").asc)
                    .fetchAll(db)
            }) ?? []
        }

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
            let escaped = target
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "%", with: "\\%")
                .replacingOccurrences(of: "_", with: "\\_")
            let prefix = Column("sourceURL").like("\(escaped)%", escape: "\\")
            return fetch(prefix)
                .filter { $0.sourceURL.map(Self.normalizedSourceURL) == target }
        }
        if let bundleID = shot.appBundleID {
            if let title = shot.windowTitle {
                return fetch(Column("appBundleID") == bundleID && Column("windowTitle") == title)
            }
            return fetch(Column("appBundleID") == bundleID)
        }
        return []
    }

    // MARK: - 语义搜索

    /// 用当前搜索框文本跑一次语义搜索，结果写进 `semanticResults`。
    /// 空查询等于清空 —— 网格退回常规列表。
    func runSemanticSearch() async {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            semanticResults = nil
            return
        }
        isSemanticSearching = true
        semanticResults = await semanticSearch(query: query)
        isSemanticSearching = false
    }

    /// 退出语义模式或清空搜索时调用。
    func clearSemanticResults() {
        semanticResults = nil
    }

    /// 按自然语言描述搜截图：查询文本过 CLIP 文本编码器，
    /// 与全部图像向量算余弦相似度（向量已归一化，等于点积），降序取前 `limit` 张。
    ///
    /// 线程边界与 `similarShots` 相同：候选载荷在主 actor 上一次性拉出，
    /// 反序列化和点积挪到后台，算完回主 actor 按 ID 取 Shot。
    /// 全量线性扫描，512 维 × 几千张在毫秒量级。
    func semanticSearch(query: String, limit: Int = 30) async -> [Shot] {
        guard let queryVector = await CLIPEncoder.shared.embedText(query) else { return [] }

        // 同上：语义搜索要拉全库的 CLIP 向量，走后台连接。
        let candidates = await attributePayloadsInBackground(key: AttributeKey.clipEmbedding)
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
        (try? dbQueue.read { db in
            try Shot.filter(ids.contains(Column("id"))).fetchAll(db)
        }) ?? []
    }

    /// 自动清理的候选：拍摄早于 `cutoff`、未收藏、没打过标签、且从未标注过。
    ///
    /// 「从未标注过」= 修订数 ≤ 1，即只有入库时自动建的那条「原始」空修订 ——
    /// 截图时标注、钉图上画、编辑器里改，任何一笔都会追加修订、让计数超过 1，
    /// 从而永久脱离清理范围。打过标签同理豁免 —— 用户亲手组织过的图，
    /// 就是在说「我在意它」。按时间升序：一批删不完时先删最老的，剩下的留给下次。
    func cleanupCandidates(olderThan cutoff: Date, limit: Int) -> [Shot] {
        (try? dbQueue.read { db in
            try Shot.fetchAll(db, sql: """
                SELECT shot.* FROM shot
                LEFT JOIN revision ON revision.shotID = shot.id
                WHERE shot.capturedAt < :cutoff
                  AND shot.id NOT IN (
                      SELECT shotID FROM shotAttribute WHERE key = 'favorite'
                  )
                  AND NOT EXISTS (
                      SELECT 1 FROM shotAttribute
                      WHERE shotID = shot.id AND key = 'tag'
                  )
                GROUP BY shot.id
                HAVING COUNT(revision.id) <= 1
                ORDER BY shot.capturedAt ASC
                LIMIT :limit
                """, arguments: ["cutoff": cutoff, "limit": limit])
        }) ?? []
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
