import Foundation
import CoreGraphics
import Combine

/// 读侧：图库、编辑器、预览只需读，不触写。
@MainActor
protocol ShotReading: AnyObject {
    var shots: [Shot] { get }
    var displayShots: [Shot] { get }
    var searchText: String { get set }
    var filter: ShotStore.GalleryFilter { get set }
    var semanticMode: Bool { get }
    var semanticResults: [Shot]? { get }
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
    func allMatchingIDs() async -> [Int64]
    func allTags() -> [(name: String, count: Int)]
    func shotsMissingAttribute(key: String) -> [Shot]
    var totalCount: Int { get }
}

/// 写侧：保存、删除、修订、收藏、标签。
@MainActor
protocol ShotWriting: AnyObject {
    @discardableResult func save(image: CGImage, metadata: CaptureMetadata) throws -> Shot
    func delete(_ shots: [Shot])
    func delete(_ shot: Shot)
    @discardableResult func appendRevision(shot: Shot, layers: Layers<ImageSpace>, note: String?) -> Revision?
    func toggleFavorite(_ shot: Shot)
    func addTag(shotID: Int64, _ tag: String)
    func removeTag(shotID: Int64, _ tag: String)
    func renameTag(_ old: String, to new: String)
    func deleteTag(_ tag: String)
    func attachMoleculeSource(_ source: MoleculeSourceAttachment, to shot: Shot) throws
}

/// 可观察：需要订阅刷新的视图。
///
/// # 发布语义（ShotStore 现状的契约化）
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
/// - `reload()`：同步查询（主线程 `dbQueue.read`），赋值后经 `publish` 发两条信号。
///   保留给**需要立即可读**的调用方：测试、`GalleryWindowController.show(selecting:)`
///   这类“先刷新再选中”场景。
/// - `reloadInBackground()`：`await dbQueue.read` 在后台读连接上执行，`publish` 回主线程。
///   节流路径（`setNeedsReload` 的 leading/trailing 0.5s 合并、截图落库、属性回填、
///   批量删除）全部走它，UI 订阅式无需立即可读。
/// - `setNeedsReload()`：leading + trailing 0.5s 节流，密集写入坍缩为 ≤2Hz。
///   外部不应直接调 `reload`，除非需要同步语义。
/// - `loadNextPage()`：游标分页追加，`objectWillChange` 前发，`libraryDidChange` 不发。
///
/// ## 演进方向
///
/// ARCHITECTURE 阶段 6 剩余项：`ShotDatabase` 非 MainActor 仓库承接全部 SQL、
/// `ValueObservation` 替代手动通知、UI 状态（`searchText`/`filter`/`semantic`）
/// 迁出为 `GalleryViewModel`。届时 `libraryDidChange` 将由
/// `ValueObservation` 驱动，本协议保持不变，订阅方无需改动。
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
    var displayShots: [Shot] { get }
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
