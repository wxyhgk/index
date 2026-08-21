import Foundation
import GRDB

/// 挂在一张图库封面 Shot 上的非图片资产。
///
/// Shot 继续承担统一时间线里的视觉封面；录像、XYZ 等原始资料住在这里，避免
/// 用无类型的 `shotAttribute.payload` 伪装文件关系。`kind` 直接表达附件用途，
/// 其余信息能从 kind 或数据本身推出时不重复存储。
struct ShotAsset: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Equatable {
    static let databaseTableName = "shotAsset"

    var id: Int64?
    var shotID: Int64
    var kind: String
    /// 外部文件路径，例如录屏 MP4。内嵌附件留空。
    var path: String?
    /// 内嵌原始数据，例如 `MoleculeSourceAttachment` JSON。
    var payload: Data?
    var schemaVersion: Int
    var createdAt: Date
    var updatedAt: Date

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

enum ShotAssetKind {
    static let recording = "recording"
    static let moleculeXYZ = "molecule.xyz"
}
