import Foundation
import GRDB

/// 通用内容记录（1:1 关联 shot，不是所有 shot 都有记录）。
/// 纯图片 shot 没有 shotContent 行；结构化内容（代码/表格/Markdown）才有。
struct ShotContent: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Equatable {
    static let databaseTableName = "shotContent"
    var id: Int64?
    var shotID: Int64
    var kind: String
    var confidence: Double
    var createdAt: Date
}

/// 代码类型专属扩展表（第一个要用的结构化类型）。
struct ContentCode: Codable, FetchableRecord, MutablePersistableRecord, Equatable {
    static let databaseTableName = "contentCode"
    var contentID: Int64
    var language: String?
    var text: String
}

/// Markdown 类型专属扩展表。
/// 截图自动生成或手动新建，source 是 Markdown 原文。
struct ContentMarkdown: Codable, FetchableRecord, MutablePersistableRecord, Equatable {
    static let databaseTableName = "contentMarkdown"
    var contentID: Int64
    var source: String
}
