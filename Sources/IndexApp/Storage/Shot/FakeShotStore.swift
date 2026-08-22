import Foundation
import CoreGraphics
import Combine

// MARK: - FakeShotStore
//
// 单测替身：用纯内存实现 `ShotReading` / `ShotWriting`，零 GRDB、零 SQLite。
// 覆盖 `ShotStore` 的可观察状态与读写契约，让 GalleryBatch / GallerySelection /
// 多选详情栏等上层逻辑可以在不建库、不落盘的条件下被单测驱动。
//
// 设计要点
// ---------
// 1. 与 `ShotStore` 同构的 API 面：实现 `ShotReading` + `ShotWriting` 协议，
//    调用方通过依赖注入 `reader:` / `writer:` 即可无缝替换（见 `GalleryBatch` 各方法）。
// 2. 状态显式可控：`shots`、`favoriteIDs` 等直接暴露为可读写存储属性，
//    图库查询状态由 `GalleryViewModel` 持有，不在存储替身里复制第二份。
// 3. 文件兜底：真实 `ShotStore` 把原图按 sha256 写到 `originals/`，`GalleryBatch.exportAll`
//    走 `originalURL` + `ImageCodec.load`，而 `copyImages` 走 `originalImage(for:)`。
//    Fake 两条路径都兼容——`save` 时把 PNG 写到临时目录，`originalImage` 也可直接命中
//    内存缓存，避免在 CI 上因缺文件而假失败。
// 4. 轻量过滤：真库的搜索/筛选是一条复杂的 FTS + LIKE + 游标 SQL，Fake 不复刻它，
//    只提供“足够让 GalleryBatch 测通”的内存谓词（appName / windowTitle / sourceURL /
//    ocrText 的大小写不敏感包含）。需要精确断言 SQL 的用例继续走 `DatabaseQueue` 内存库
//    的 `ShotStoreTests`；Fake 专注上层装配逻辑。
// 5. MainActor 隔离：与 `ShotReading` / `ShotWriting` 保持 `@MainActor`，单测里
//    `await MainActor.run {}` 或直接标记 `@MainActor` 即可。

@MainActor
final class FakeShotStore: ObservableObject, ShotReading, ShotWriting, ShotObserving {

    // MARK: 可观察状态（对齐 ShotStore）

    /// 图库当前展示的列表。测试可直接赋值，无需经过 reload。
    var shots: [Shot] = [] {
        didSet { objectWillChange.send() }
    }

    private(set) var favoriteIDs: Set<Int64> = [] {
        didSet { objectWillChange.send() }
    }

    // MARK: ShotObserving

    let libraryDidChange = PassthroughSubject<Void, Never>()
    var hasMorePages: Bool { false }

    // MARK: 内存后端

    /// 自增主键。贴近 GRDB 的 rowID 行为。
    private var nextID: Int64 = 1
    /// 修订表：shotID -> [Revision]（按 createdAt/id 升序）
    private var revisionsStore: [Int64: [Revision]] = [:]
    /// 标签表：shotID -> Set<tag>
    private var tagsStore: [Int64: Set<String>] = [:]
    /// 通用属性二进制载荷：shotID -> key -> Data
    private var payloadStore: [Int64: [String: Data]] = [:]
    /// 类型化附件与真实 `shotAsset` 分开建模，避免测试替身掩盖旧属性依赖。
    private var moleculeSourceStore: [Int64: MoleculeSourceAttachment] = [:]
    private var recordingPathStore: [Int64: String] = [:]
    /// 原图内存缓存：sha256 -> CGImage（供 originalImage 快速命中）
    private var imageCache: [String: CGImage] = [:]

    /// 文件兜底目录。`save` 时写入，`originalURL` 指向此处，保证 ImageCodec.load 能命中。
    let rootDirectory: URL
    let originalsDirectory: URL
    let thumbnailsDirectory: URL

    // MARK: 初始化

    init(
        rootDirectory: URL? = nil,
        shots initialShots: [Shot] = [],
        favoriteIDs: Set<Int64> = [],
        revisions: [Int64: [Revision]] = [:]
    ) {
        let base = rootDirectory ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("FakeShotStore-\(UUID().uuidString)", isDirectory: true)
        self.rootDirectory = base
        self.originalsDirectory = base.appendingPathComponent("originals", isDirectory: true)
        self.thumbnailsDirectory = base.appendingPathComponent("thumbnails", isDirectory: true)
        for dir in [base, originalsDirectory, thumbnailsDirectory] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        self.favoriteIDs = favoriteIDs
        self.revisionsStore = revisions

        // 通过 insert 统一分配 ID/索引，避免测试手填 id 冲突。
        for s in initialShots {
            _ = insert(s)
        }
        // nextID 必须在已插入的最大值之后
        if let maxID = shots.compactMap(\.id).max() {
            nextID = maxID + 1
        }
    }

    deinit {
        // 尽力清理临时目录；失败忽略（CI 上无副作用）。
        // 非 MainActor 上下文，避免在 deinit 里触及 MainActor 状态。
        let root = rootDirectory
        Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: root)
        }
    }

    // MARK: - 测试辅助：直接预置数据

    /// 直接插入一条已构造的 Shot，自动分配 id（若为 nil），并写入 `shots`。
    /// 返回落库后的 Shot（含 id）——与 `save(image:metadata:)` 的返回值语义一致。
    @discardableResult
    func insert(_ shot: Shot, image: CGImage? = nil) -> Shot {
        var s = shot
        if s.id == nil {
            s.id = nextID
            nextID += 1
        } else {
            nextID = max(nextID, (s.id ?? 0) + 1)
        }
        shots.append(s)
        // 保证至少有一条「原始」修订，与真库 `save` 行为一致
        if revisionsStore[s.id!] == nil {
            var rev = Revision.make(shotID: s.id!, parentID: nil, layers: [], note: "原始")
            rev.id = 1
            revisionsStore[s.id!] = [rev]
        }
        if let image {
            imageCache[s.sha256] = image
            persistImage(image, sha256: s.sha256)
        }
        objectWillChange.send()
        return s
    }

    /// 预置收藏状态。
    func setFavorite(_ shotID: Int64, isFavorite: Bool) {
        if isFavorite { favoriteIDs.insert(shotID) } else { favoriteIDs.remove(shotID) }
    }

    /// 预置修订链。
    func setRevisions(for shotID: Int64, revisions: [Revision]) {
        revisionsStore[shotID] = revisions
    }

    /// 预置一条属性载荷（如 clipEmbedding / featurePrint）。
    func setPayload(shotID: Int64, key: String, data: Data?) {
        if let data {
            var m = payloadStore[shotID] ?? [:]
            m[key] = data
            payloadStore[shotID] = m
        } else {
            payloadStore[shotID]?[key] = nil
        }
    }

    /// 清空全部状态，利于 between-tests 复用同一实例。
    func removeAll() {
        shots.removeAll()
        favoriteIDs.removeAll()
        revisionsStore.removeAll()
        tagsStore.removeAll()
        payloadStore.removeAll()
        moleculeSourceStore.removeAll()
        recordingPathStore.removeAll()
        imageCache.removeAll()
        nextID = 1
        objectWillChange.send()
    }

    // MARK: - ShotReading

    func originalURL(for shot: Shot) -> URL {
        originalsDirectory.appendingPathComponent(shot.originalFileName)
    }

    func thumbnailURL(for shot: Shot) -> URL {
        thumbnailsDirectory.appendingPathComponent(shot.thumbnailFileName)
    }

    func originalImage(for shot: Shot) -> CGImage? {
        if let cached = imageCache[shot.sha256] { return cached }
        return ImageCodec.load(from: originalURL(for: shot))
    }

    func revisions(for shot: Shot) -> [Revision] {
        guard let id = shot.id else { return [] }
        return revisionsStore[id]?.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return ($0.id ?? 0) < ($1.id ?? 0)
        } ?? []
    }

    func latestRevision(for shot: Shot) -> Revision? {
        revisions(for: shot).last
    }

    func isFavorite(shotID: Int64) -> Bool {
        favoriteIDs.contains(shotID)
    }

    func allShots(limit: Int = ShotStore.pageSize) -> [Shot] {
        let sorted = shots.sorted { ($0.capturedAt, $0.id ?? 0) > ($1.capturedAt, $1.id ?? 0) }
        return Array(sorted.prefix(limit))
    }

    func relatedShots(to shot: Shot) -> [Shot] {
        // 复刻 ShotStore.relatedShots 的三级判定
        if let source = shot.sourceURL {
            let target = ShotStore.normalizedSourceURL(source)
            return shots.filter { $0.sourceURL.map(ShotStore.normalizedSourceURL) == target }
                .sorted { ($0.capturedAt, $0.id ?? 0) < ($1.capturedAt, $1.id ?? 0) }
        }
        if let bundleID = shot.appBundleID {
            if let title = shot.windowTitle {
                return shots.filter { $0.appBundleID == bundleID && $0.windowTitle == title }
                    .sorted { ($0.capturedAt, $0.id ?? 0) < ($1.capturedAt, $1.id ?? 0) }
            }
            return shots.filter { $0.appBundleID == bundleID }
                .sorted { ($0.capturedAt, $0.id ?? 0) < ($1.capturedAt, $1.id ?? 0) }
        }
        return []
    }

    func cleanupCandidates(olderThan date: Date, limit: Int) -> [Shot] {
        shots.filter { shot in
            guard shot.capturedAt < date else { return false }
            guard let id = shot.id else { return false }
            if favoriteIDs.contains(id) { return false }
            if let tags = tagsStore[id], !tags.isEmpty { return false }
            if recordingPathStore[id] != nil { return false }
            if moleculeSourceStore[id] != nil { return false }
            let revCount = revisionsStore[id]?.count ?? 0
            // 真库：COUNT(revision.id) <= 1（含「原始」那条）
            if revCount > 1 { return false }
            return true
        }
        .sorted { $0.capturedAt < $1.capturedAt }
        .prefix(limit)
        .map { $0 }
    }

    func attributePayload(shotID: Int64, key: String) -> Data? {
        payloadStore[shotID]?[key]
    }

    func moleculeSource(for shot: Shot) -> MoleculeSourceAttachment? {
        guard let shotID = shot.id else { return nil }
        return moleculeSourceStore[shotID]
    }

    func recordingPath(for shot: Shot) -> String? {
        guard let id = shot.id else { return nil }
        return recordingPathStore[id]
    }

    func recordingPaths(for shotIDs: [Int64]) -> [Int64: String] {
        let ids = Set(shotIDs)
        return recordingPathStore.filter { ids.contains($0.key) }
    }

    func recordingCount() -> Int {
        recordingPathStore.count
    }

    func allMatchingIDs(query rawQuery: String, filter: ShotFilter) async -> [Int64] {
        // 内存谓词：与 ShotStore.fetchShots 的意图一致，但简化为包含匹配。
        // 真正的 FTS/trigram 精确性由 ShotStoreTests 覆盖，Fake 只需让
        // “全选 = 符合当前条件的所有 ID” 这一语义可测。
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let matched = shots.filter { shot in
            guard passesFilter(shot, filter: filter) else { return false }
            guard !query.isEmpty else { return true }
            return matchesQuery(shot, query: query)
        }
        let sorted = matched.sorted { ($0.capturedAt, $0.id ?? 0) > ($1.capturedAt, $1.id ?? 0) }
        return sorted.compactMap(\.id)
    }

    func shotsInBackground(ids: [Int64]) async -> [Shot] {
        let byID = Dictionary(uniqueKeysWithValues: shots.compactMap { shot in
            shot.id.map { ($0, shot) }
        })
        var seen = Set<Int64>()
        return ids.filter { seen.insert($0).inserted }.compactMap { byID[$0] }
    }

    func outputMaterialsInBackground(ids: [Int64]) async -> [ShotOutputMaterial] {
        let resolved = await shotsInBackground(ids: ids)
        return resolved.map { shot in
            ShotOutputMaterial(
                shot: shot,
                originalURL: originalURL(for: shot),
                layers: latestRevision(for: shot)?.imageLayers ?? Layers()
            )
        }
    }

    func allTags() -> [(name: String, count: Int)] {
        var counter: [String: Int] = [:]
        for tags in tagsStore.values {
            for t in tags { counter[t, default: 0] += 1 }
        }
        return counter.map { (name: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }
    }

    func shotsMissingAttribute(key: String) -> [Shot] {
        shots.filter { shot in
            guard let id = shot.id else { return false }
            if key == AttributeKey.ocrText, let t = shot.ocrText, !t.isEmpty { return false }
            if key == AttributeKey.sourceURL, let u = shot.sourceURL, !u.isEmpty { return false }
            return payloadStore[id]?[key] == nil
        }
    }

    var totalCount: Int { shots.count }

    func markdownSource(for shot: Shot) -> String? {
        // 内存版不维护 contentMarkdown 表，调用方兜底生成。
        nil
    }

    // MARK: - 额外读辅助（供 GalleryBatch 以外调用方）

    func tags(shotID: Int64) -> [String] {
        Array(tagsStore[shotID] ?? []).sorted()
    }

    // MARK: - ShotWriting

    @discardableResult
    func save(image: CGImage, metadata: CaptureMetadata, originalData: Data?, originalExtension: String?) throws -> Shot {
        let shot = saveInternal(image: image, metadata: metadata, originalExtension: originalExtension)
        return shot
    }

    @discardableResult
    func save(image: CGImage, metadata: CaptureMetadata) throws -> Shot {
        try save(image: image, metadata: metadata, originalData: nil, originalExtension: nil)
    }

    private func saveInternal(image: CGImage, metadata: CaptureMetadata, originalExtension: String?) -> Shot {
        // 简化版内容寻址：用时间 + 尺寸生成伪 sha，满足“同内容去重”在 Fake 中不强求。
        // 测试若需去重语义，可直接用 insert(_:image:) 预置相同 sha。
        let sha = fakeSHA(for: image)
        // 已存在同 sha 的文件则复用（贴近真库的去重语义，但不强制合并 Shot 记录）
        let shot = Shot(
            id: nextID,
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
            originalExtension: originalExtension
        )
        nextID += 1
        shots.append(shot)
        var rev = Revision.make(shotID: shot.id!, parentID: nil, layers: [], note: "原始")
        rev.id = 1
        revisionsStore[shot.id!] = [rev]
        imageCache[sha] = image
        persistImage(image, sha256: sha)
        objectWillChange.send()
        return shot
    }

    func delete(_ shotsToDelete: [Shot]) {
        delete(shotIDs: shotsToDelete.compactMap(\.id))
    }

    func delete(shotIDs: [Int64]) {
        let ids = Set(shotIDs)
        guard !ids.isEmpty else { return }
        let shas = Set(shots.compactMap { shot in
            shot.id.map(ids.contains) == true ? shot.sha256 : nil
        })

        shots.removeAll { $0.id.map { ids.contains($0) } ?? false }
        for id in ids {
            revisionsStore[id] = nil
            tagsStore[id] = nil
            payloadStore[id] = nil
            moleculeSourceStore[id] = nil
            recordingPathStore[id] = nil
            favoriteIDs.remove(id)
        }
        // 引用计数：sha 仍被剩余记录引用则保留文件
        let remainingShas = Set(shots.map(\.sha256))
        let orphaned = shas.subtracting(remainingShas)
        for sha in orphaned {
            imageCache[sha] = nil
            try? FileManager.default.removeItem(at: originalsDirectory.appendingPathComponent("\(sha).png"))
            try? FileManager.default.removeItem(at: thumbnailsDirectory.appendingPathComponent("\(sha).jpg"))
        }
        objectWillChange.send()
    }

    func delete(_ shot: Shot) {
        delete([shot])
    }

    @discardableResult
    func appendRevision(shot: Shot, layers: Layers<ImageSpace>, note: String?) -> Revision? {
        guard let id = shot.id, shots.contains(where: { $0.id == id }) else { return nil }
        var list = revisionsStore[id] ?? []
        let parentID = list.last?.id
        var rev = Revision.make(shotID: id, parentID: parentID, layers: layers.persisted, note: note)
        // 简易自增
        rev.id = (list.map { $0.id ?? 0 }.max() ?? 0) + 1
        list.append(rev)
        revisionsStore[id] = list
        objectWillChange.send()
        return rev
    }

    func toggleFavorite(_ shot: Shot) {
        guard let id = shot.id else { return }
        if favoriteIDs.contains(id) {
            favoriteIDs.remove(id)
        } else {
            favoriteIDs.insert(id)
        }
        objectWillChange.send()
    }

    func setFavorite(shotIDs: [Int64], isFavorite: Bool) {
        let existing = Set(shots.compactMap(\.id))
        let ids = Set(shotIDs).intersection(existing)
        if isFavorite {
            favoriteIDs.formUnion(ids)
        } else {
            favoriteIDs.subtract(ids)
        }
        objectWillChange.send()
    }

    func addTag(shotID: Int64, _ tag: String) {
        let name = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        var set = tagsStore[shotID] ?? Set()
        set.insert(name)
        tagsStore[shotID] = set
        objectWillChange.send()
    }

    func removeTag(shotID: Int64, _ tag: String) {
        tagsStore[shotID]?.remove(tag)
        objectWillChange.send()
    }

    func renameTag(_ old: String, to new: String) {
        let name = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != old else { return }
        for (id, var set) in tagsStore {
            if set.contains(old) {
                set.remove(old)
                set.insert(name)
                tagsStore[id] = set
            }
        }
        objectWillChange.send()
    }

    func deleteTag(_ tag: String) {
        for (id, var set) in tagsStore {
            set.remove(tag)
            tagsStore[id] = set
        }
        objectWillChange.send()
    }

    func setCustomTitle(_ title: String?, for shot: Shot) {
        guard let id = shot.id,
              let index = shots.firstIndex(where: { $0.id == id })
        else { return }
        objectWillChange.send()
        shots[index].customTitle = Shot.normalizedCustomTitle(title)
    }

    /// 通用属性写入（供 Pipeline 注入使用）。`ocrText`/`sourceURL` 写回 Shot，通用 key 进 payload。
    func writeAttribute(shotID: Int64, key: String, value: AttributeValue) {
        switch (key, value) {
        case (AttributeKey.ocrText, .text(let text)):
            if let idx = shots.firstIndex(where: { $0.id == shotID }) {
                shots[idx].ocrText = text
            }
        case (AttributeKey.sourceURL, .text(let url)):
            if let idx = shots.firstIndex(where: { $0.id == shotID }) {
                shots[idx].sourceURL = url
            }
        default:
            var map = payloadStore[shotID] ?? [:]
            if let data = value.payload {
                map[key] = data
            } else if let text = value.searchableText {
                map[key] = Data(text.utf8)
            } else {
                map[key] = Data()
            }
            payloadStore[shotID] = map
        }
        objectWillChange.send()
    }

    func saveContent(for shotID: Int64, kind: ContentKind, payload: ContentPayload, updateKind: Bool) throws {
        if let idx = shots.firstIndex(where: { $0.id == shotID }) {
            if updateKind {
                shots[idx].contentKind = kind.rawValue
            }
        }
        objectWillChange.send()
    }

    @discardableResult
    func createMarkdownShot(title: String, source: String) throws -> Shot {
        var shot = Shot(
            id: nil,
            sha256: UUID().uuidString,
            capturedAt: Date(),
            pixelWidth: 0,
            pixelHeight: 0,
            scale: 1.0,
            appName: nil,
            appBundleID: nil,
            appVersion: nil,
            appBuild: nil,
            windowTitle: title,
            sourceURL: nil,
            displayID: nil,
            displayName: nil,
            regionX: 0,
            regionY: 0,
            regionW: 0,
            regionH: 0,
            ocrText: nil
        )
        shot.contentKind = "markdown"
        let id = nextID
        nextID += 1
        shot.id = id
        shots.insert(shot, at: 0)
        objectWillChange.send()
        return shot
    }

    func attachMoleculeSource(_ source: MoleculeSourceAttachment, to shot: Shot) throws {
        guard let shotID = shot.id else { throw ShotStore.StoreError.missingShotID }
        moleculeSourceStore[shotID] = source
        objectWillChange.send()
    }

    func attachRecording(at url: URL, to shot: Shot) throws {
        guard let shotID = shot.id else { throw ShotStore.StoreError.missingShotID }
        recordingPathStore[shotID] = url.path
        objectWillChange.send()
    }

    func removeAttribute(shotID: Int64, key: String) {
        payloadStore[shotID]?[key] = nil
        if payloadStore[shotID]?.isEmpty == true {
            payloadStore[shotID] = nil
        }
        objectWillChange.send()
    }

    // MARK: - 私有

    private func passesFilter(_ shot: Shot, filter: ShotFilter) -> Bool {
        switch filter {
        case .all: return true
        case .favorites: return shot.id.map { favoriteIDs.contains($0) } ?? false
        case .untagged:
            guard let id = shot.id else { return true }
            return tagsStore[id]?.isEmpty ?? true
        case .annotated:
            guard let id = shot.id else { return false }
            return (revisionsStore[id]?.count ?? 0) > 1
        case .recordings:
            guard let id = shot.id else { return false }
            return recordingPathStore[id] != nil
        case .category(let name):
            // Fake 未单独维护 category，退化为 tags 包含即命中，便于演示
            guard let id = shot.id else { return false }
            return tagsStore[id]?.contains(name) ?? false
        case .tag(let name):
            guard let id = shot.id else { return false }
            return tagsStore[id]?.contains(name) ?? false
        case .app(let identity):
            if let bundleID = identity.bundleID {
                return shot.appBundleID == bundleID
            }
            let bundleID = shot.appBundleID?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (bundleID == nil || bundleID?.isEmpty == true) && shot.appName == identity.name
        case .collection:
            // Fake 暂不模拟专题集关系；真实关系契约由 ShotStore 数据库测试覆盖。
            return false
        }
    }

    private func matchesQuery(_ shot: Shot, query: String) -> Bool {
        let q = query.lowercased()
        func contains(_ s: String?) -> Bool {
            guard let s, !s.isEmpty else { return false }
            return s.lowercased().contains(q)
        }
        if contains(shot.appName) { return true }
        if contains(shot.customTitle) { return true }
        if contains(shot.windowTitle) { return true }
        if contains(shot.sourceURL) { return true }
        if contains(shot.ocrText) { return true }
        if let id = shot.id, let tags = tagsStore[id] {
            if tags.contains(where: { $0.lowercased().contains(q) }) { return true }
        }
        return false
    }

    private func fakeSHA(for image: CGImage) -> String {
        // 足够唯一即可：用尺寸 + 首像素 + UUID，测试里可用 insert 指定固定 sha
        "\(image.width)x\(image.height)-\(UUID().uuidString.prefix(8))"
    }

    private func persistImage(_ image: CGImage, sha256: String) {
        guard let png = ImageCodec.pngData(from: image) else { return }
        let originalPath = originalsDirectory.appendingPathComponent("\(sha256).png")
        if !FileManager.default.fileExists(atPath: originalPath.path) {
            try? png.write(to: originalPath, options: .atomic)
        }
        let thumbPath = thumbnailsDirectory.appendingPathComponent("\(sha256).jpg")
        if !FileManager.default.fileExists(atPath: thumbPath.path),
           let thumb = ImageCodec.resized(image, maxDimension: 640),
           let jpg = ImageCodec.jpegData(from: thumb) {
            try? jpg.write(to: thumbPath, options: .atomic)
        }
    }
}

// MARK: - 便捷构造（测试用）

extension FakeShotStore {
    /// 预览用的轻量样本库：6 张不同 App/标题/时间，用于 SwiftUI Preview 无需建库即可渲染。
    /// 每张均带内存缩略图兜底，GalleryGrid / ShotDetailPane 等无需落盘即可显示占位。
    static var preview: FakeShotStore {
        let store = FakeShotStore()
        let now = Date()
        let seeds: [(String, String, String)] = [
            ("Finder", "访达 — 项目文件", "https://example.com/finder"),
            ("Safari", "Index — 视觉资料库", "https://example.com/index"),
            ("Xcode", "Index.xcodeproj", "https://example.com/xcode"),
            ("Figma", "Design — Index 标注", "https://example.com/figma"),
            ("Slack", "团队频道 #design", "https://example.com/slack"),
            ("Notes", "会议纪要 08-08", "https://example.com/notes"),
        ]
        for (idx, seed) in seeds.enumerated() {
            var shot = makeShot(
                id: Int64(idx + 1),
                appName: seed.0,
                windowTitle: seed.1,
                sourceURL: seed.2,
                capturedAt: now.addingTimeInterval(Double(-idx) * 3600)
            )
            // 随机尺寸让瀑布流预览更真实
            shot.pixelWidth = [1440, 900, 1200][idx % 3]
            shot.pixelHeight = [900, 1200, 800][idx % 3]
            _ = store.insert(shot)
            if idx == 0 {
                store.setFavorite(shot.id ?? Int64(idx + 1), isFavorite: true)
            }
            if idx == 2 {
                store.addTag(shotID: shot.id ?? Int64(idx + 1), "工作")
            }
        }
        return store
    }

    /// 快速造一条最小 Shot，无需 CGImage。
    static func makeShot(
        id: Int64? = nil,
        sha256: String? = nil,
        appName: String? = nil,
        windowTitle: String? = nil,
        sourceURL: String? = nil,
        capturedAt: Date = Date()
    ) -> Shot {
        Shot(
            id: id,
            sha256: sha256 ?? UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
            capturedAt: capturedAt,
            pixelWidth: 800,
            pixelHeight: 600,
            scale: 2,
            appName: appName,
            appBundleID: nil,
            appVersion: nil,
            appBuild: nil,
            windowTitle: windowTitle,
            sourceURL: sourceURL,
            displayID: nil,
            displayName: nil,
            regionX: 0, regionY: 0, regionW: 800, regionH: 600,
            ocrText: nil
        )
    }
}
