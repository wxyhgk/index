import AppKit
import Foundation

// MARK: - Agent 插件（= 超级插件）
//
// agent 不是外挂，是插件系统里的一个插件 —— 它能调用所有其他插件的能力。
//
// "软件自己改自己" = agent 通过工具修改 registry 状态（安装/卸载插件、改配置、
// 加 hook），不改二进制。
//
// 执行方式：
//   · 本地：RuleEngine（如果 X 则 Y 的规则链，零延迟、离线）
//   · 远程：调 LLM API（用户配 key，后续阶段）
//
// 当前骨架：注册核心工具 + 挂 afterCapture hook 跑本地规则引擎。

@MainActor
final class AgentPlugin: Plugin {
    let id = "agent"
    let displayName = "Agent"
    let version = "1.0"

    static let shared = AgentPlugin()

    private let ruleEngine = RuleEngine()
    private var tools: [AgentTool] = []
    private var settings: (any PluginPreferences)?

    func activate(_ ctx: PluginContext) {
        // 注册核心工具（agent 能调用的操作）
        tools = Self.builtinTools(ctx: ctx)
        settings = ctx.settings

        // 挂 afterCapture hook：截图后跑本地规则引擎
        HookRegistry.shared.on(.afterCapture) { [weak self] context in
            guard let self else { return }
            await self.ruleEngine.run(context: context)
        }
    }

    func deactivate(_ ctx: PluginContext) {
        HookRegistry.shared.clear(.afterCapture)
    }

    /// agent 的工具表（= LLM function calling 的 tools）。
    var availableTools: [AgentTool] { tools }

    /// 是否已配置（有 API key 且启用）。
    var isConfigured: Bool {
        guard let settings, settings.agentEnabled else { return false }
        return AgentLLMClient(
            baseURL: settings.agentBaseURL,
            model: settings.agentModel,
            apiKey: settings.agentAPIKey
        ).isConfigured
    }

    /// 问 agent 一句话（LLM 对话，自动调工具）。
    /// - Returns: agent 的回答文本。
    func ask(_ message: String) async -> String {
        guard let settings, settings.agentEnabled else {
            return "Agent 未启用（设置 → 插件 → Agent）"
        }
        let client = AgentLLMClient(
            baseURL: settings.agentBaseURL,
            model: settings.agentModel,
            apiKey: settings.agentAPIKey
        )
        guard client.isConfigured else {
            return "Agent 未配置 API key（设置 → 插件 → Agent）"
        }
        return await client.run(userMessage: message, tools: tools)
    }

    // MARK: - 内置工具

    private static func builtinTools(ctx: PluginContext) -> [AgentTool] {
        [
            AgentTool(
                name: "list_plugins",
                description: "列出所有已激活的插件（id / 名称 / 版本）",
                parameters: [:],
                execute: { _ in
                    await MainActor.run {
                        let plugins = ctx.pluginManager.activePlugins
                        return plugins.map { "\($0.id) (\($0.displayName) v\($0.version))" }.joined(separator: "\n")
                    }
                }
            ),
            AgentTool(
                name: "search_shots",
                description: "按关键词搜索截图（全文索引：OCR 文字 / 标题 / 分类）",
                parameters: ["query": "搜索关键词"],
                execute: { input in
                    guard let query = input["query"], !query.isEmpty else { return "缺少 query 参数" }
                    return await MainActor.run {
                        let shots = ctx.shotStore.allShots(limit: 20)
                        let matches = shots.filter { shot in
                            (shot.ocrText ?? "").localizedCaseInsensitiveContains(query)
                            || (shot.windowTitle ?? "").localizedCaseInsensitiveContains(query)
                        }
                        guard !matches.isEmpty else { return "未找到匹配「\(query)」的截图" }
                        return matches.prefix(5).map {
                            "id=\($0.id ?? -1) \($0.windowTitle ?? $0.primaryDisplayName) \($0.capturedAt.formatted(.dateTime.month().day().hour().minute()))"
                        }.joined(separator: "\n")
                    }
                }
            ),
            AgentTool(
                name: "list_content_kinds",
                description: "列出所有内容类型及其行为描述（= major mode）",
                parameters: [:],
                execute: { _ in
                    await MainActor.run {
                        let kinds = ctx.pluginRegistry.registeredKinds
                        return kinds.map { kind in
                            let mode = ctx.pluginRegistry.mode(for: kind)
                            return "\(kind.rawValue): label=\(mode.label) doubleClick=\(mode.doubleClick) keymap=\(mode.keymap.keys.sorted())"
                        }.joined(separator: "\n")
                    }
                }
            ),
            AgentTool(
                name: "set_config",
                description: "修改软件配置（快捷键 / 样式 / 布局）。key 是配置项名，value 是新值",
                parameters: ["key": "配置项名", "value": "新值"],
                execute: { input in
                    // 当前骨架：只记录，不真正改（后续接 AppSettings）
                    return "已记录配置变更: \(input["key"] ?? "?") = \(input["value"] ?? "?")"
                }
            ),
        ]
    }
}
