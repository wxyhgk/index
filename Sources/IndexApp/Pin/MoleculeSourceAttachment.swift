import Foundation

/// 与一张分子快照关联的不可变来源。
///
/// XYZ 不写进 PNG 元数据：导出图片不会意外携带坐标，图片优化或平台转码也不会
/// 抹掉来源。载荷单独存进 `shotAsset`，工具栏只在载荷存在时显示分子入口。
struct MoleculeSourceAttachment: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let format: String
    let canonicalXYZ: String
    let atomCount: Int
    let createdAt: Date

    init(canonicalXYZ: String, atomCount: Int, createdAt: Date = Date()) {
        self.schemaVersion = Self.currentSchemaVersion
        self.format = "xyz"
        self.canonicalXYZ = canonicalXYZ
        self.atomCount = atomCount
        self.createdAt = createdAt
    }
}
