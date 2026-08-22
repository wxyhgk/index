import Foundation

struct OpenAICompatibleSelectionAIConfiguration: Equatable, Sendable {
    let baseURL: String
    let model: String
    let timeout: TimeInterval

    init(baseURL: String, model: String, timeout: TimeInterval = 60) {
        self.baseURL = baseURL
        self.model = model
        self.timeout = timeout
    }

    /// 拼出 /chat/completions 端点。支持 http 和 https。
    var responseURL: URL? {
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
        } else if path.hasSuffix("/responses") {
            path = String(path.dropLast("/responses".count)) + "/chat/completions"
        } else {
            path += "/chat/completions"
        }
        components.path = path
        return components.url
    }

    var normalizedModel: String {
        model.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum OpenAICompatibleSelectionAIError: LocalizedError {
    case missingAPIKey
    case invalidConfiguration
    case imageEncodingFailed
    case imageTooLarge(Int)
    case invalidRequest
    case network(Error)
    case httpFailure(Int, String?)
    case missingOutput
    case invalidStructuredOutput

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: "尚未在设置中保存 AI API Key"
        case .invalidConfiguration: "AI Base URL 或模型名称无效"
        case .imageEncodingFailed: "无法编码 AI 选区图片"
        case let .imageTooLarge(bytes):
            "AI 选区图片过大（\(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))）"
        case .invalidRequest: "无法构造 AI 请求"
        case let .network(error): "AI 请求失败：\(error.localizedDescription)"
        case let .httpFailure(status, message):
            message.map { "AI 服务返回 HTTP \(status)：\($0)" } ?? "AI 服务返回 HTTP \(status)"
        case .missingOutput: "AI 服务没有返回可用文本"
        case .invalidStructuredOutput: "AI 服务返回的结构化结果无法解析"
        }
    }
}

/// 信任所有证书的 delegate（本地模型服务器自签名/无证书）。
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

/// OpenAI-compatible Chat Completions API 实现。
/// 支持本地模型（vLLM/Ollama/LM Studio）和云端 OpenAI 兼容端点。
struct OpenAICompatibleSelectionAIProvider: SelectionAIProvider {
    let id = "openai-compatible"
    let supportedTasks = Set(SelectionAITaskKind.allCases)

    private let configuration: OpenAICompatibleSelectionAIConfiguration
    private let credentialStore: any SelectionAIAPIKeyStoring
    private let session: URLSession

    /// 共享的 trust-all session（本地服务器自签名/无证书）。
    private static let trustAllSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        return URLSession(configuration: config, delegate: TrustAllDelegate(), delegateQueue: nil)
    }()

    init(
        configuration: OpenAICompatibleSelectionAIConfiguration,
        credentialStore: any SelectionAIAPIKeyStoring = MacSelectionAIKeychain.shared,
        session: URLSession? = nil
    ) {
        self.configuration = configuration
        self.credentialStore = credentialStore
        self.session = session ?? Self.trustAllSession
    }

    var isAvailable: Bool {
        configuration.responseURL != nil
            && !configuration.normalizedModel.isEmpty
            && ((try? credentialStore.loadAPIKey()) ?? nil) != nil
    }

    func perform(_ request: SelectionAIRequest) async throws -> SelectionAIResult {
        let urlRequest = try makeURLRequest(for: request)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw OpenAICompatibleSelectionAIError.network(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw OpenAICompatibleSelectionAIError.missingOutput
        }
        guard (200..<300).contains(http.statusCode) else {
            throw OpenAICompatibleSelectionAIError.httpFailure(
                http.statusCode,
                Self.providerErrorMessage(from: data)
            )
        }
        return try Self.parseResult(from: data, task: request.task)
    }

    func makeURLRequest(for request: SelectionAIRequest) throws -> URLRequest {
        guard let url = configuration.responseURL,
              !configuration.normalizedModel.isEmpty
        else { throw OpenAICompatibleSelectionAIError.invalidConfiguration }
        guard let apiKey = try credentialStore.loadAPIKey(), !apiKey.isEmpty else {
            throw OpenAICompatibleSelectionAIError.missingAPIKey
        }
        let policy = SelectionAIRequestPolicy.policy(for: request.task.kind)
        let encodedImage: SelectionAIEncodedImage
        do {
            encodedImage = try SelectionAIImageEncoder.encode(
                request.input.image,
                policy: policy
            )
        } catch SelectionAIImageEncoderError.remainsTooLarge(let bytes) {
            throw OpenAICompatibleSelectionAIError.imageTooLarge(bytes)
        } catch {
            throw OpenAICompatibleSelectionAIError.imageEncodingFailed
        }

        let prompt = Self.prompt(for: request.task, request: request)
        let imageDataURL = "data:\(encodedImage.mimeType);base64,\(encodedImage.data.base64EncodedString())"

        // Chat Completions API 格式
        let body: [String: Any] = [
            "model": configuration.normalizedModel,
            "messages": [
                [
                    "role": "system",
                    "content": "你是一个结构化 JSON 输出助手。严格按用户要求的 JSON schema 返回，不要加任何额外文字或代码围栏。"
                ],
                [
                    "role": "user",
                    "content": [
                        ["type": "text", "text": prompt],
                        ["type": "image_url", "image_url": ["url": imageDataURL]]
                    ]
                ]
            ],
            "max_tokens": policy.maxOutputTokens,
            "temperature": 0.1
        ]
        guard JSONSerialization.isValidJSONObject(body) else {
            throw OpenAICompatibleSelectionAIError.invalidRequest
        }

        var urlRequest = URLRequest(url: url, timeoutInterval: configuration.timeout)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        return urlRequest
    }

    // MARK: - 响应解析

    static func parseResult(from data: Data, task: SelectionAITask) throws -> SelectionAIResult {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = outputText(from: root)
        else { throw OpenAICompatibleSelectionAIError.missingOutput }

        let json = normalizedJSONText(text)
        guard let jsondata = json.data(using: .utf8),
              let payload = try? JSONDecoder().decode(StructuredPayload.self, from: jsondata),
              payload.kind == task.kind.rawValue
        else {
            // 容错：模型没严格返回 kind 字段时，尝试直接解析
            if let jsondata = json.data(using: .utf8),
               let fallback = try? JSONDecoder().decode(StructuredPayload.self, from: jsondata) {
                return try makeResult(from: fallback, task: task)
            }
            throw OpenAICompatibleSelectionAIError.invalidStructuredOutput
        }
        return try makeResult(from: payload, task: task)
    }

    private static func makeResult(from payload: StructuredPayload, task: SelectionAITask) throws -> SelectionAIResult {
        switch task {
        case .explain:
            return .explanation(markdown: payload.markdown ?? payload.primary)
        case let .translate(targetLanguage):
            return .translation(.init(
                text: payload.primary,
                sourceLanguage: payload.sourceLanguage,
                targetLanguage: payload.targetLanguage ?? targetLanguage
            ))
        case .formulaToLaTeX:
            return .formula(.init(latex: payload.primary))
        case .extractTable:
            guard let markdown = payload.markdown, let csv = payload.csv else {
                throw OpenAICompatibleSelectionAIError.invalidStructuredOutput
            }
            return .table(.init(markdown: markdown, csv: csv))
        }
    }

    /// 从 Chat Completions 响应提取文本。
    private static func outputText(from root: [String: Any]) -> String? {
        guard let choices = root["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String,
              !content.isEmpty
        else { return nil }
        return content
    }

    private static func normalizedJSONText(_ text: String) -> String {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // 去掉 markdown 代码围栏
        if trimmed.hasPrefix("```") {
            if trimmed.hasPrefix("```json") { trimmed = String(trimmed.dropFirst(7)) }
            else if trimmed.hasPrefix("```") { trimmed = String(trimmed.dropFirst(3)) }
            if trimmed.hasSuffix("```") { trimmed = String(trimmed.dropLast(3)) }
            trimmed = trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // 提取第一个 { ... } 块（模型可能在 JSON 前后加了说明文字）
        if let start = trimmed.firstIndex(of: "{"),
           let end = trimmed.lastIndex(of: "}") {
            trimmed = String(trimmed[start...end])
        }
        return trimmed
    }

    private static func providerErrorMessage(from data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        // OpenAI 格式: {"error": {"message": "..."}}
        if let error = root["error"] as? [String: Any],
           let message = error["message"] as? String {
            return String(message.prefix(240))
        }
        // vLLM/Ollama 格式: {"error": "string"}
        if let error = root["error"] as? String {
            return String(error.prefix(240))
        }
        return nil
    }

    // MARK: - Prompt

    private static func prompt(for task: SelectionAITask, request: SelectionAIRequest) -> String {
        let common = "只分析用户提供的截图选区。不要猜测选区外的上下文。"
        let schema = """
        严格返回如下 JSON（不要加代码围栏或额外文字）：
        {"kind":"\(task.kind.rawValue)","primary":"...","markdown":null,"csv":null,"source_language":null,"target_language":null}
        """
        var prompt: String
        switch task {
        case .explain:
            prompt = "\(common) 用中文解释画面内容；primary 和 markdown 都给出完整 Markdown 说明，其余可空字段返回 null。"
        case let .translate(targetLanguage):
            prompt = "\(common) 识别画面文字并翻译为 \(targetLanguage)，保留专业术语、公式和段落；primary 只放译文，并填写语言字段。"
        case .formulaToLaTeX:
            prompt = "\(common) 识别其中的数学或化学公式；primary 只返回可复制的 LaTeX 源码，不加代码围栏。"
        case .extractTable:
            prompt = "\(common) 按视觉行列提取表格；primary 与 markdown 放完整 Markdown 表格，csv 放符合 RFC 4180 的 CSV。"
        }
        prompt += "\n\(schema)"
        if let instruction = request.instruction?.trimmingCharacters(in: .whitespacesAndNewlines),
           !instruction.isEmpty {
            prompt += "\n用户补充要求：\(instruction)"
        }
        if let recognized = request.input.recognizedText?.trimmingCharacters(in: .whitespacesAndNewlines),
           !recognized.isEmpty {
            prompt += "\n本地 OCR 参考文本：\n\(recognized)"
        }
        return prompt
    }

    private struct StructuredPayload: Decodable {
        let kind: String
        let primary: String
        let markdown: String?
        let csv: String?
        let sourceLanguage: String?
        let targetLanguage: String?

        enum CodingKeys: String, CodingKey {
            case kind, primary, markdown, csv
            case sourceLanguage = "source_language"
            case targetLanguage = "target_language"
        }
    }
}
