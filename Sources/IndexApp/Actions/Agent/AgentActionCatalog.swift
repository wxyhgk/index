import Foundation

/// Agent 可以计划的动作。枚举是 UI、LLM tool 与执行器共用的稳定标识。
enum AgentActionKind: String, CaseIterable, Sendable {
    case setFavorite = "set_favorite"
    case addTag = "add_tag"
    case exportZIP = "export_zip"
}

/// 可列举的动作能力描述。`isAvailable == false` 只用于告诉 Agent 路线图，不能生成计划。
struct AgentActionDescriptor: Equatable, Sendable {
    let kind: AgentActionKind
    let title: String
    let summary: String
    let argumentHelp: String
    let isDestructive: Bool
    let isAvailable: Bool
}

enum AgentActionCatalog {
    static let descriptors: [AgentActionDescriptor] = [
        AgentActionDescriptor(
            kind: .setFavorite,
            title: "批量设置收藏",
            summary: "把查询命中的内容统一设为收藏或取消收藏。执行前必须预览并确认。",
            argumentHelp: "value=true 或 false",
            isDestructive: false,
            isAvailable: true
        ),
        AgentActionDescriptor(
            kind: .addTag,
            title: "批量添加标签",
            summary: "给查询命中的内容添加同一个标签。重复添加是幂等的。执行前必须预览并确认。",
            argumentHelp: "value=标签名",
            isDestructive: false,
            isAvailable: true
        ),
        AgentActionDescriptor(
            kind: .exportZIP,
            title: "筛选结果导出 ZIP",
            summary: "按查询结果打包导出；等待通用 ZIP 导出服务接入后开放。",
            argumentHelp: "暂不可用",
            isDestructive: false,
            isAvailable: false
        )
    ]

    static func descriptor(for kind: AgentActionKind) -> AgentActionDescriptor? {
        descriptors.first { $0.kind == kind }
    }
}

