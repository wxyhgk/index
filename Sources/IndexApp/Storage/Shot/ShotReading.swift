import Foundation
import CoreGraphics
import Combine

/// 复制、导出等“生成成品”动作所需的不可变输入。数据库在后台一次取好 Shot 与
/// 最新修订，主线程只负责组装原图 URL；随后整个值会转移给后台渲染任务。
struct ShotOutputMaterial: Equatable, @unchecked Sendable {
    let shot: Shot
    let originalURL: URL
    let layers: Layers<ImageSpace>
}

/// 读侧：图库、编辑器、预览只需读，不触写。
@MainActor
protocol ShotReading: AnyObject {
    var shots: [Shot] { get }
    var favoriteIDs: Set<Int64> { get }

    func originalURL(for shot: Shot) -> URL
    func thumbnailURL(for shot: Shot) -> URL
    func originalImage(for shot: Shot) -> CGImage?
    func revisions(for shot: Shot) -> [Revision]
    func latestRevision(for shot: Shot) -> Revision?
    func isFavorite(shotID: Int64) -> Bool
    func allShots(limit: Int) -> [Shot]
    func relatedShots(to shot: Shot) -> [Shot]
    func cleanupCandidates(olderThan date: Date, limit: Int) -> [Shot]
    func attributePayload(shotID: Int64, key: String) -> Data?
    func moleculeSource(for shot: Shot) -> MoleculeSourceAttachment?
    func recordingPath(for shot: Shot) -> String?
    func recordingPaths(for shotIDs: [Int64]) -> [Int64: String]
    func recordingCount() -> Int
    func allMatchingIDs(query: String, filter: ShotFilter) async -> [Int64]
    /// 按调用方给定顺序解析任意数量的 ID。生产实现必须走后台读并分块，不能受当前分页限制。
    func shotsInBackground(ids: [Int64]) async -> [Shot]
    /// 在同一数据库快照中批量取得 Shot 与各自最新修订，避免批量复制/导出逐张查库。
    func outputMaterialsInBackground(ids: [Int64]) async -> [ShotOutputMaterial]
    func allTags() -> [(name: String, count: Int)]
    func shotsMissingAttribute(key: String) -> [Shot]
    var totalCount: Int { get }
    /// 取 shot 的 Markdown 源码（收口三步查询：content → contentID → markdownContent）。
    /// 没有存储的 Markdown 时返回 nil，调用方自行决定兜底策略。
    func markdownSource(for shot: Shot) -> String?
}

/// 写侧：保存、删除、修订、收藏、标签。
@MainActor
protocol ShotWriting: AnyObject {
    @discardableResult func save(image: CGImage, metadata: CaptureMetadata) throws -> Shot
    @discardableResult func save(image: CGImage, metadata: CaptureMetadata, originalData: Data?, originalExtension: String?) throws -> Shot
    func delete(_ shots: [Shot])
    func delete(_ shot: Shot)
    @discardableResult func appendRevision(shot: Shot, layers: Layers<ImageSpace>, note: String?) -> Revision?
    func toggleFavorite(_ shot: Shot)
    /// 一次事务设置一批收藏状态；跨分页全选不得退化成逐张写入风暴。
    func setFavorite(shotIDs: [Int64], isFavorite: Bool)
    /// 直接按 ID 批量删除；无需先把后续分页全部装成主线程对象。
    func delete(shotIDs: [Int64])
    func addTag(shotID: Int64, _ tag: String)
    func removeTag(shotID: Int64, _ tag: String)
    func renameTag(_ old: String, to new: String)
    func deleteTag(_ tag: String)
    func setCustomTitle(_ title: String?, for shot: Shot)
    func attachMoleculeSource(_ source: MoleculeSourceAttachment, to shot: Shot) throws
    func attachRecording(at url: URL, to shot: Shot) throws
    func writeAttribute(shotID: Int64, key: String, value: AttributeValue)
    func saveContent(for shotID: Int64, kind: ContentKind, payload: ContentPayload, updateKind: Bool) throws
    @discardableResult func createMarkdownShot(title: String, source: String) throws -> Shot
}

/// 可观察：需要订阅刷新的视图。
///
/// # 发布语义
///
/// `ShotStore` 是 `@MainActor final class ObservableObject`，但 `shots` / `favoriteIDs`
/// 刻意**不是** `@Published`，而在 `publish(shots:favorites:)` 里手动合并为
/// 一次 `objectWillChange.send()`：
///
/// ```swift
/// objectWillChange.send()
/// shots = newShots
/// favoriteIDs = newFavoriteIDs
/// hasMorePages = newShots.count >= Self.pageSize
/// libraryDidChange.send()
/// ```
///
/// 两个 `@Published` 各发一次会导致侧边栏聚合查询、详情栏、胶片条等订阅方
/// 每轮 `reload` 级联重查两遍，故合为一次发布（见 `ShotStore.swift` 注释）。
///
/// ## 两条信号的分工
///
/// | 信号 | 时机 | 可否同步读 `shots` | 典型订阅方 |
/// |---|---|---|---|
/// | `objectWillChange` | **变更前**（SwiftUI 契约）。任何写入都会发：`publish`、分页 `loadNextPage` 的 `append`、单张 `appendRevision`。 | ❌ 需 `receive(on: RunLoop.main)` 或 `DispatchQueue.main.async` 后再读 | 图库网格（`@ObservedObject`）、QuickLook（`receive(on:)` 后 `reloadShots`）、详情页单行查询 |
/// | `libraryDidChange` | **变更后**。仅当库存重查完成（`reload` / `reloadInBackground` 经 `publish`）才发，此时 `shots`/`favoriteIDs` 已赋值。分页追加与修订保存**不发**。 | ✅ 同步读即可 | 编辑器胶片条（`allShots()` 全库）、侧边栏计数 |
///
/// 为什么胶片条必须只订 `libraryDidChange`：`appendRevision` 每 1–2s 发一次
/// `objectWillChange`（自动保存），若胶片条订它，会在主线程上每秒重查全库
/// （500 行取回 + 解码），表现为编辑时点按钮延迟（见 `EditorFilmstrip` 注释）。
/// `loadNextPage` 同理只发 `objectWillChange` 不发 `libraryDidChange`——库存没变
/// 只是多显示一段，发后者会让胶片条无谓重查。
///
/// ## 刷新机制
///
/// - `ShotQueryRepository.observeLibrary` 用 GRDB `ValueObservation` 持续观察 Shot、属性、
///   附件与收藏集表；提交后在同一数据库快照里重查当前页和收藏集合。
/// - `reload()`：同步取消旧观察、建立新查询观察，并立即发布首个快照。保留给测试、
///   `GalleryWindowController.show(selecting:)` 等需要立即可读的调用方。
/// - `reloadInBackground()`：异步建立同一份持续观察并等待首个快照；生产 `DatabasePool`
///   可在非主线程取值，迟到的旧观察由 generation + 查询快照一起丢弃。
/// - `loadNextPage()`：游标分页追加，`objectWillChange` 前发，`libraryDidChange` 不发。
/// - 普通修订表不在库存观察范围内；仅 `.annotated` 筛选观察修订。这样编辑器自动保存
///   仍只发轻量 `objectWillChange`，不会反复重查胶片条与侧边栏聚合。
@MainActor
protocol ShotObserving: ObservableObject {
    /// 库存内容已重查并赋值完成。订阅方可同步读取 `shots` / `favoriteIDs`。
    /// 分页追加与修订追加不发此信号。
    var libraryDidChange: PassthroughSubject<Void, Never> { get }

    /// 是否还有下一页（`shots.count >= pageSize` 的乐观判定，整数倍时会多翻一次空页）。
    var hasMorePages: Bool { get }

    /// 当前展示的列表（分页受限）与收藏集合。由 `objectWillChange` / `libraryDidChange`
    /// 驱动刷新；在 `ShotReading` 中亦有声明，此处重申以使单凭 `ShotObserving`
    /// 即可完成订阅-读取闭环。
    var shots: [Shot] { get }
    var favoriteIDs: Set<Int64> { get }
}

extension ShotObserving {
    /// 库存变更的擦除发布者，便于 `.onReceive` / `.sink` 而不暴露 Subject 可发送能力。
    var libraryDidChangePublisher: AnyPublisher<Void, Never> {
        libraryDidChange.eraseToAnyPublisher()
    }

    /// 订阅库存变更（变更后，已可同步读）。返回的 `AnyCancellable` 需由调用方持有。
    @discardableResult
    func sinkLibraryDidChange(
        receiveValue: @escaping () -> Void
    ) -> AnyCancellable {
        libraryDidChange.sink { _ in receiveValue() }
    }

    /// 订阅任意存储变更（变更前，需下一 runloop 再读）。
    /// 已自动 `receive(on: RunLoop.main)`，回调中可安全地 `DispatchQueue.main.async` 或直接由
    /// SwiftUI 的 `@ObservedObject` 失效驱动下一帧读取。
    @discardableResult
    func sinkStoreWillChange(
        receiveValue: @escaping () -> Void
    ) -> AnyCancellable {
        objectWillChange
            .receive(on: RunLoop.main)
            .sink { _ in receiveValue() }
    }
}

extension ShotReading {
    func allShots() -> [Shot] { allShots(limit: ShotStore.pageSize) }
}

extension ShotStore: ShotReading, ShotWriting, ShotObserving {}
