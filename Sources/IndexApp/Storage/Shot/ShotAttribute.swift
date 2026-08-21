import Foundation
import GRDB

/// 一条派生属性。谁产出的、什么含义，由 `key` 决定，存储层不解释。
struct ShotAttribute: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "shotAttribute"

    var id: Int64?
    var shotID: Int64
    var key: String
    /// 可搜索的文本表示。
    var text: String?
    /// 二进制载荷（向量之类）。
    var payload: Data?
    var createdAt: Date

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// 派生属性的取值。
enum AttributeValue {
    case text(String)
    /// 附带一个用于检索的文本摘要，没有就传 nil。
    case data(Data, searchableText: String?)
}

extension AttributeValue {
    var searchableText: String? {
        switch self {
        case .text(let text): return text
        case .data(_, let summary): return summary
        }
    }

    var payload: Data? {
        switch self {
        case .text: return nil
        case .data(let data, _): return data
        }
    }
}

/// 内置属性的 key。
enum AttributeKey {
    static let ocrText = "ocr.text"
    static let sourceURL = "source.url"
    /// 规则分类结果（中文分类名，见 `ShotClassifier`）。
    static let category = "category"
    /// 用户自定义标签。**多值 key**：一张图多个标签 = 多行，
    /// 读写走 `ShotAttributeRepository` 的多值标签入口，
    /// 不要走单值替换入口（它会「同 key 先删后插」）。
    /// text = 标签名，自动进 attributeFts，搜标签名直接命中。
    static let tag = "tag"
    /// Vision 场景标签，逗号分隔的 identifier 列表。
    static let visionLabels = "vision.labels"
    /// 收藏标记。存在即为已收藏，text 必须为 nil（不进全文索引）。
    static let favorite = "favorite"
    /// Vision 图像特征指纹（NSKeyedArchiver 序列化的 VNFeaturePrintObservation）。
    /// 二进制载荷，text 必须为 nil（不进全文索引）。
    static let featurePrint = "vision.featureprint"
    /// MobileCLIP-S0 图像向量（512 维 Float32 的原始字节，已归一化）。
    /// 二进制载荷，text 必须为 nil（不进全文索引）。key 带版本号 ——
    /// 换模型时换 key，新旧向量不会被误比。
    static let clipEmbedding = "clip.embedding.v1"
    /// 敏感内容检测结果（[SensitiveRegion] 的 JSON）。
    /// searchableText 只放命中的**种类**汇总（如 "邮箱,密钥"）——
    /// 具体内容（邮箱地址、密钥本身）绝不进全文索引。
    static let sensitiveRegions = "sensitive.regions"
}

/// 只供数据库迁移读取的历史 key。业务代码不得再通过通用属性接口访问附件。
enum LegacyAttributeKey {
    static let recordingPath = "recording.path"
    static let moleculeXYZSource = "source.molecule.xyz.v1"
}
