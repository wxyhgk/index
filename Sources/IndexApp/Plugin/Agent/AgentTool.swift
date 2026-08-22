import Foundation

// MARK: - Agent 工具（= LLM function calling 的 tool）
//
// agent 能调用的操作。每个工具 = 名字 + 描述（给 LLM 看的）+ 执行闭包。
// 本地规则引擎和远程 LLM 共用同一份工具表 —— 工具是"软件能做什么"的唯一事实源。

struct AgentTool: Sendable {
    /// 工具名（LLM function name，小写连字符）。
    let name: String
    /// 给 LLM 看的描述（决定它什么时候调这个工具）。
    let description: String
    /// 参数 schema（简化版：参数名 → 说明，后续接 JSON Schema）。
    let parameters: [String: String]
    /// 执行闭包。input 是参数键值对，返回结果文本（回给 LLM 或规则引擎）。
    let execute: @Sendable ([String: String]) async -> String
}

// MARK: - Agent 事件（工具调用过程回调，驱动前端实时展示）

enum AgentEvent: Sendable {
    case toolCallStarted(name: String, args: String)
    case toolCallFinished(name: String, result: String)
    case response(String)
}
