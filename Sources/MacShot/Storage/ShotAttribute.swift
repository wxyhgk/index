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
    /// Vision 场景标签，逗号分隔的 identifier 列表。
    static let visionLabels = "vision.labels"
    /// 收藏标记。存在即为已收藏，text 必须为 nil（不进全文索引）。
    static let favorite = "favorite"
    /// Vision 图像特征指纹（NSKeyedArchiver 序列化的 VNFeaturePrintObservation）。
    /// 二进制载荷，text 必须为 nil（不进全文索引）。
    static let featurePrint = "vision.featureprint"
}
