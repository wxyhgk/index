import Foundation
import GRDB

/// 用户创建的专题收藏集。它只保存组织信息，图片成员位于 `shotCollectionItem`。
struct ShotCollection: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Equatable {
    static let databaseTableName = "shotCollection"

    var id: Int64?
    var name: String
    var note: String
    var coverShotID: Int64?
    var createdAt: Date
    var updatedAt: Date
    var sortOrder: Int

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

struct ShotCollectionItem: Codable, FetchableRecord, PersistableRecord, Equatable {
    static let databaseTableName = "shotCollectionItem"

    var collectionID: Int64
    var shotID: Int64
    var addedAt: Date
    var sortOrder: Int
}

/// 收藏首页需要的一次性快照，避免卡片渲染时逐个查询数据库。
struct ShotCollectionSummary: Identifiable, Equatable {
    let id: Int64
    let name: String
    let note: String
    let itemCount: Int
    let updatedAt: Date
    let previews: [Shot]
}

enum ShotCollectionError: LocalizedError, Equatable {
    case emptyName
    case duplicateName
    case collectionNotFound

    var errorDescription: String? {
        switch self {
        case .emptyName: return "收藏集名称不能为空"
        case .duplicateName: return "已经有同名收藏集"
        case .collectionNotFound: return "收藏集已不存在"
        }
    }
}
