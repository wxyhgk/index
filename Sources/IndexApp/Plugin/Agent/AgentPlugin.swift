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
    func ask(
        _ message: String,
        history: [[String: Any]] = [],
        onEvent: (@Sendable (AgentEvent) -> Void)? = nil
    ) async -> String {
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
        return await client.run(userMessage: message, tools: tools, history: history, onEvent: onEvent)
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
                description: "按关键词搜索截图（全文索引：OCR 文字 / 标题 / 分类）。query 可以包含多个关键词（空格分隔），会拆开后分别搜索取并集",
                parameters: ["query": "搜索关键词（可多个，空格分隔）"],
                execute: { input in
                    guard let query = input["query"], !query.isEmpty else { return "缺少 query 参数" }
                    // 拆成关键词分别搜，取并集（FTS 短语匹配对自然语言太严格）
                    let keywords = query.split(separator: " ").map(String.init).filter { !$0.isEmpty }
                    var idSet = Set<Int64>()
                    for kw in keywords {
                        // FTS trigram 区分大小写，同时搜原始和 lowercase
                        for variant in [kw, kw.lowercased()] {
                            let ids = await ctx.shotStore.allMatchingIDs(query: variant, filter: .all)
                            idSet.formUnion(ids)
                        }
                    }
                    guard !idSet.isEmpty else { return "未找到匹配「\(query)」的截图" }
                    let sorted = idSet.sorted { a, b in a > b }
                    let shots = await ctx.shotStore.shotsInBackground(ids: Array(sorted.prefix(5)))
                    return shots.map { shot in
                        var line = "id=\(shot.id ?? -1) \((shot.windowTitle ?? shot.primaryDisplayName).prefix(80)) \n"
                        if let ocr = shot.ocrText, !ocr.isEmpty {
                            line += "OCR: \(ocr.prefix(500))"
                        }
                        return line
                    }.joined(separator: "\n---\n")
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
                name: "list_config_keys",
                description: "列出所有可修改的配置项名（改配置前先查这个）",
                parameters: [:],
                execute: { _ in
                    await MainActor.run {
                        ConfigSetter.availableKeys.joined(separator: "\n")
                    }
                }
            ),
            AgentTool(
                name: "set_config",
                description: "修改软件配置。先用 list_config_keys 查可用项，key 是配置项名，value 是新值（布尔用 true/false，数字用整数，文本直接给）",
                parameters: ["key": "配置项名", "value": "新值"],
                execute: { input in
                    guard let key = input["key"], let value = input["value"] else {
                        return "缺少 key 或 value 参数"
                    }
                    return await MainActor.run { ConfigSetter.apply(key: key, value: value) }
                }
            ),
            AgentTool(
                name: "open_shot",
                description: "在图库中打开指定截图（用户说'打开/查看'某张截图时用）",
                parameters: ["id": "截图 id（数字）"],
                execute: { input in
                    guard let idStr = input["id"], let id = Int64(idStr) else {
                        return "缺少 id 参数"
                    }
                    let shots = await ctx.shotStore.shotsInBackground(ids: [id])
                    guard let shot = shots.first else { return "未找到 id=\(id) 的截图" }
                    await MainActor.run {
                        ctx.openShot(shot)
                    }
                    return "已打开截图 id=\(id)"
                }
            ),
        ]
    }
}
