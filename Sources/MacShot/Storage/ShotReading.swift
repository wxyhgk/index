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
    func allMatchingIDs() async -> [Int64]
    func allTags() -> [(name: String, count: Int)]
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
}

/// 可观察：需要订阅刷新的视图。
protocol ShotObserving: ObservableObject {}

extension ShotReading {
    func allShots() -> [Shot] { allShots(limit: ShotStore.pageSize) }
}

extension ShotStore: ShotReading, ShotWriting, ShotObserving {}
