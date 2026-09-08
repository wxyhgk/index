import Foundation

/// ShotFilter 的可序列化输入形态。Agent 不需要知道 Gallery 的状态类型。
enum AgentShotFilterSpec: Equatable, Sendable {
    case all
    case favorites
    case untagged
    case annotated
    case recordings
    case category(String)
    case tag(String)
    case app(name: String, bundleID: String?)
    case collection(Int64)

    var shotFilter: ShotFilter {
        switch self {
        case .all: .all
        case .favorites: .favorites
        case .untagged: .untagged
        case .annotated: .annotated
        case .recordings: .recordings
        case .category(let name): .category(name)
        case .tag(let name): .tag(name)
        case let .app(name, bundleID): .app(CapturedAppIdentity(name: name, bundleID: bundleID))
        case .collection(let id): .collection(id)
        }
    }

    var displayName: String {
        switch self {
        case .all: "all"
        case .favorites: "favorites"
        case .untagged: "untagged"
        case .annotated: "annotated"
        case .recordings: "recordings"
        case .category(let value): "category:\(value)"
        case .tag(let value): "tag:\(value)"
        case let .app(name, bundleID): "app:\(bundleID ?? name)"
        case .collection(let id): "collection:\(id)"
        }
    }
}

enum AgentActionPayload: Equatable, Sendable {
    case setFavorite(Bool)
    case addTag(String)

    var kind: AgentActionKind {
        switch self {
        case .setFavorite: .setFavorite
        case .addTag: .addTag
        }
    }

    var summary: String {
        switch self {
        case .setFavorite(let value): value ? "设为收藏" : "取消收藏"
        case .addTag(let tag): "添加标签「\(tag)」"
        }
    }
}

struct AgentActionDraft: Equatable, Sendable {
    let query: String
    let filter: AgentShotFilterSpec
    let payload: AgentActionPayload
}

struct AgentActionSample: Equatable, Sendable {
    let id: Int64
    let title: String
    let capturedAt: Date
}

/// 查询时冻结的计划。ID 列表不会在执行时被替换；查询漂移会让计划整体失效。
struct AgentActionPlan: Equatable, Sendable {
    let id: String
    let confirmationToken: String
    let createdAt: Date
    let expiresAt: Date
    let draft: AgentActionDraft
    let shotIDs: [Int64]
    let samples: [AgentActionSample]

    var matchCount: Int { shotIDs.count }
}

struct AgentActionExecution: Equatable, Sendable {
    let planID: String
    let action: AgentActionKind
    let affectedCount: Int
}

enum AgentActionPlanError: LocalizedError, Equatable {
    case unsupportedAction(String)
    case unavailableAction(AgentActionKind)
    case invalidArgument(String)
    case emptyResult
    case confirmationRequired
    case planNotFound
    case invalidToken
    case expired
    case queryDrifted

    var errorDescription: String? {
        switch self {
        case .unsupportedAction(let value): "不支持的动作：\(value)"
        case .unavailableAction(let kind): "动作 \(kind.rawValue) 尚未开放"
        case .invalidArgument(let message): message
        case .emptyResult: "查询没有命中内容，未创建计划"
        case .confirmationRequired: "执行前必须显式传入 confirm=true"
        case .planNotFound: "计划不存在或已执行，请重新生成预览"
        case .invalidToken: "确认令牌不匹配，请使用预览返回的 confirmation_token"
        case .expired: "计划已过期，请重新生成预览"
        case .queryDrifted: "查询结果已发生变化，未执行任何动作；请重新生成预览"
        }
    }
}

