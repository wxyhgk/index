import Foundation

// MARK: - Agent LLM 客户端（原生 URLSession + Chat Completions API）
//
// 不用 MacPaw/OpenAI SDK —— SDK 硬编码 https 且不支持自定义端口，
// 本地模型服务器（vLLM/Ollama/LM Studio）通常只开 http://host:port/v1。
// 这里直接用 URLSession + trust-all delegate，和 OpenAICompatibleSelectionAIProvider 一致。

struct AgentLLMClient: Sendable {

    let baseURL: String
    let model: String
    let apiKey: String

    var isConfigured: Bool { !apiKey.isEmpty && !baseURL.isEmpty }

    // MARK: - 请求

    func run(
        userMessage: String,
        tools: [AgentTool],
        history: [[String: Any]] = [],
        maxRounds: Int = 5,
        onEvent: (@Sendable (AgentEvent) -> Void)? = nil
    ) async -> String {
        guard isConfigured, let url = makeURL() else {
            return "Agent 未配置（设置 → 插件 → Agent）"
        }

        var messages: [[String: Any]] = [
            [
                "role": "system",
                "content": """
                    你是 Index 截图软件的内置 agent。你可以调用工具来查询截图、管理插件、修改配置。
                    回答用中文，简洁直接。

                    重要规则：
                    - 当用户提到"查/搜/有没有/找"某个内容时，**必须**先调用 search_shots 在截图库里搜索，不要凭自己的知识回答。
                    - search_shots 的 query 用简短核心关键词（如 "DeepSeek" 而非 "DeepSeek api 的价格"），多个关键词用空格分隔。
                    - 搜索有结果时，基于结果回答；没结果时告诉用户"截图库里没搜到"，不要编造。
                    - 不要回答截图库之外的问题（如天气、新闻），告诉用户你只能查截图和管理配置。
                    """
            ]
        ]
        messages.append(contentsOf: history)
        messages.append(["role": "user", "content": userMessage])

        let sdkTools: [[String: Any]] = tools.map { tool in
            let properties: [String: Any] = tool.parameters.mapValues { desc in
                ["type": "string", "description": desc]
            }
            return [
                "type": "function",
                "function": [
                    "name": tool.name,
                    "description": tool.description,
                    "parameters": [
                        "type": "object",
                        "properties": properties,
                        "required": Array(tool.parameters.keys)
                    ]
                ]
            ]
        }

        for _ in 0..<maxRounds {
            var body: [String: Any] = [
                "model": model,
                "messages": messages
            ]
            if !sdkTools.isEmpty {
                body["tools"] = sdkTools
                body["tool_choice"] = "auto"
            }

            let data: Data
            do {
                data = try await post(url: url, body: body)
            } catch {
                NSLog("[Agent] LLM 请求失败: \(error.localizedDescription)")
                return "LLM 请求失败: \(error.localizedDescription)"
            }

            // 解析响应
            guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = root["choices"] as? [[String: Any]],
                  let first = choices.first,
                  let message = first["message"] as? [String: Any]
            else {
                return "（响应格式异常）"
            }

            let content = message["content"] as? String ?? ""
            let toolCalls = message["tool_calls"] as? [[String: Any]] ?? []

            if toolCalls.isEmpty {
                let answer = content.isEmpty ? "（无回答）" : content
                onEvent?(.response(answer))
                return answer
            }

            // 有工具调用
            var assistantMsg: [String: Any] = [
                "role": "assistant",
                "content": content
            ]
            if !toolCalls.isEmpty {
                assistantMsg["tool_calls"] = toolCalls
            }
            messages.append(assistantMsg)

            for call in toolCalls {
                guard let fn = call["function"] as? [String: Any],
                      let name = fn["name"] as? String,
                      let argsStr = fn["arguments"] as? String
                else { continue }

                let args: [String: String] = (try? JSONSerialization.jsonObject(
                    with: Data(argsStr.utf8)
                )).flatMap { $0 as? [String: String] } ?? [:]

                onEvent?(.toolCallStarted(name: name, args: argsStr))
                let toolResult = await executeTool(name: name, args: args, tools: tools)
                onEvent?(.toolCallFinished(name: name, result: toolResult))

                let callID = call["id"] as? String ?? "call_\(UUID().uuidString.prefix(8))"

                messages.append([
                    "role": "tool",
                    "tool_call_id": callID,
                    "content": toolResult
                ])
            }
        }
        return "（达到最大工具调用轮数）"
    }

    // MARK: - 工具执行

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

    // MARK: - HTTP

    private func makeURL() -> URL? {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              components.host != nil
        else { return nil }
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        if path.hasSuffix("/chat/completions") {
            // 用户直接填了完整端点
        } else {
            path += "/chat/completions"
        }
        components.path = path
        return components.url
    }

    private func post(url: URL, body: [String: Any]) async throws -> Data {
        guard JSONSerialization.isValidJSONObject(body) else {
            throw AgentLLMError.invalidBody
        }
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await AgentLLMClient.trustAllSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AgentLLMError.badResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { $0["error"] as? [String: Any] }
                .flatMap { $0["message"] as? String }
                ?? (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                    .flatMap { $0["error"] as? String }
                ?? "HTTP \(http.statusCode)"
            throw AgentLLMError.http(http.statusCode, msg)
        }
        return data
    }

    // MARK: - Trust-all session

    private static let trustAllSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        return URLSession(configuration: config, delegate: TrustAllDelegate(), delegateQueue: nil)
    }()
}

// MARK: - 错误类型

enum AgentLLMError: LocalizedError {
    case invalidBody
    case badResponse
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidBody: "请求体无效"
        case .badResponse: "服务器响应异常"
        case let .http(status, msg): "HTTP \(status): \(msg)"
        }
    }
}

// MARK: - Trust-all delegate（本地服务器自签名/无证书）

private final class TrustAllDelegate: NSObject, URLSessionDelegate {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
