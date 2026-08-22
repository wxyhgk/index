import Foundation

// MARK: - Agent LLM 客户端（OpenAI 兼容 function calling）
//
// 把 AgentTool 表喂给 LLM（tools 参数），LLM 决定调哪个工具、传什么参数，
// 客户端执行工具后把结果回给 LLM，直到 LLM 给出最终回答。
//
// 端点 / 模型 / key 从 PluginPrefs 读（用户可在设置页配）。
// 当前支持 OpenAI 兼容的 /v1/chat/completions 接口。

struct AgentLLMClient: Sendable {

    let baseURL: String
    let model: String
    let apiKey: String

    /// 是否已配置（有 key 才启用）。
    var isConfigured: Bool { !apiKey.isEmpty && !baseURL.isEmpty }

    /// 跑一轮 agent 对话：用户输入 → LLM 调工具 → 最终回答。
    /// - Parameters:
    ///   - userMessage: 用户说的话
    ///   - tools: 可调用的工具表
    ///   - maxRounds: 最多几轮工具调用（防死循环）
    func run(
        userMessage: String,
        tools: [AgentTool],
        maxRounds: Int = 5
    ) async -> String {
        guard isConfigured else { return "Agent 未配置 API key（设置 → 插件 → Agent）" }

        var messages: [[String: Any]] = [
            ["role": "system", "content": "你是 Index 截图软件的内置 agent。你可以调用工具来查询截图、管理插件、修改配置。回答用中文，简洁直接。"],
            ["role": "user", "content": userMessage]
        ]

        for _ in 0..<maxRounds {
            let response = await chat(messages: messages, tools: tools)
            guard let response else { return "LLM 请求失败" }

            // 提取 content 和 tool_calls
            let content = (response["content"] as? String) ?? ""
            let toolCalls = (response["tool_calls"] as? [[String: Any]]) ?? []

            if toolCalls.isEmpty {
                // 没有工具调用，content 就是最终回答
                return content.isEmpty ? "（无回答）" : content
            }

            // 有工具调用：执行每个工具，把结果回给 LLM
            messages.append(["role": "assistant", "content": content, "tool_calls": toolCalls])
            for call in toolCalls {
                let funcInfo = (call["function"] as? [String: Any]) ?? [:]
                let name = (funcInfo["name"] as? String) ?? ""
                let argsStr = (funcInfo["arguments"] as? String) ?? "{}"
                let callID = (call["id"] as? String) ?? ""

                let args: [String: String] = (try? JSONSerialization.jsonObject(with: Data(argsStr.utf8)))
                    .flatMap { $0 as? [String: String] } ?? [:]

                let result = await executeTool(name: name, args: args, tools: tools)

                messages.append([
                    "role": "tool",
                    "tool_call_id": callID,
                    "content": result
                ])
            }
        }
        return "（达到最大工具调用轮数）"
    }

    /// 执行一个工具。
    private func executeTool(name: String, args: [String: String], tools: [AgentTool]) async -> String {
        guard let tool = tools.first(where: { $0.name == name }) else {
            return "未知工具: \(name)"
        }
        do {
            return try await withCheckedThrowingContinuation { cont in
                Task { @MainActor in
                    cont.resume(returning: await tool.execute(args))
                }
            }
        } catch {
            return "工具执行失败: \(error.localizedDescription)"
        }
    }

    /// 调 /v1/chat/completions。
    private func chat(messages: [[String: Any]], tools: [AgentTool]) async -> [String: Any]? {
        guard let url = URL(string: baseURL.hasSuffix("/") ? baseURL + "chat/completions" : baseURL + "/chat/completions") else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30

        var body: [String: Any] = [
            "model": model,
            "messages": messages,
            "stream": false
        ]

        // tools（function calling）
        if !tools.isEmpty {
            body["tools"] = tools.map { tool in
                [
                    "type": "function",
                    "function": [
                        "name": tool.name,
                        "description": tool.description,
                        "parameters": [
                            "type": "object",
                            "properties": tool.parameters.mapValues { desc in
                                ["type": "string", "description": desc]
                            }
                        ]
                    ]
                ]
            }
        }

        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                let text = String(data: data, encoding: .utf8) ?? ""
                NSLog("[Agent] LLM 请求失败 status=\(status) body=\(text.prefix(200))")
                return nil
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let first = choices.first,
                  let message = first["message"] as? [String: Any] else { return nil }
            return message
        } catch {
            NSLog("[Agent] LLM 请求异常: \(error.localizedDescription)")
            return nil
        }
    }
}
