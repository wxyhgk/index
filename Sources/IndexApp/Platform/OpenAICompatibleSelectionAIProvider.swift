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

    var responseURL: URL? {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == "https",
              components.host != nil
        else { return nil }
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        if !path.hasSuffix("/responses") { path += "/responses" }
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

/// OpenAI-compatible Responses API 实现。网络、Bearer 鉴权和凭据读取全部收在 Platform。
struct OpenAICompatibleSelectionAIProvider: SelectionAIProvider {
    let id = "openai-compatible"
    let supportedTasks = Set(SelectionAITaskKind.allCases)

    private let configuration: OpenAICompatibleSelectionAIConfiguration
    private let credentialStore: any SelectionAIAPIKeyStoring
    private let session: URLSession

    init(
        configuration: OpenAICompatibleSelectionAIConfiguration,
        credentialStore: any SelectionAIAPIKeyStoring = MacSelectionAIKeychain.shared,
        session: URLSession = .shared
    ) {
        self.configuration = configuration
        self.credentialStore = credentialStore
        self.session = session
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
        } catch SelectionAIImageEncoderError.preparationFailed {
            throw OpenAICompatibleSelectionAIError.imageEncodingFailed
        } catch SelectionAIImageEncoderError.encodingFailed {
            throw OpenAICompatibleSelectionAIError.imageEncodingFailed
        } catch {
            throw OpenAICompatibleSelectionAIError.imageEncodingFailed
        }

        let expectedKind = request.task.kind.rawValue
        var prompt = Self.prompt(for: request.task)
        if let instruction = request.instruction?.trimmingCharacters(in: .whitespacesAndNewlines),
           !instruction.isEmpty {
            prompt += "\n用户补充要求：\(instruction)"
        }
        if let recognized = request.input.recognizedText?.trimmingCharacters(in: .whitespacesAndNewlines),
           !recognized.isEmpty {
            prompt += "\n本地 OCR 参考文本：\n\(recognized)"
        }

        let nullableString: [String: Any] = ["type": ["string", "null"]]
        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "kind": ["type": "string", "enum": [expectedKind]],
                "primary": ["type": "string"],
                "markdown": nullableString,
                "csv": nullableString,
                "source_language": nullableString,
                "target_language": nullableString
            ],
            "required": [
                "kind", "primary", "markdown", "csv", "source_language", "target_language"
            ],
            "additionalProperties": false
        ]
        let body: [String: Any] = [
            "model": configuration.normalizedModel,
            "store": false,
            "reasoning": ["effort": "low"],
            "max_output_tokens": policy.maxOutputTokens,
            "input": [[
                "role": "user",
                "content": [
                    ["type": "input_text", "text": prompt],
                    [
                        "type": "input_image",
                        "image_url": "data:\(encodedImage.mimeType);base64,\(encodedImage.data.base64EncodedString())",
                        "detail": "high"
                    ]
                ]
            ]],
            "text": [
                "format": [
                    "type": "json_schema",
                    "name": "index_selection_ai_result",
                    "strict": true,
                    "schema": schema
                ]
            ]
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

    static func parseResult(from data: Data, task: SelectionAITask) throws -> SelectionAIResult {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = outputText(from: root),
              let json = normalizedJSONText(text).data(using: .utf8),
              let payload = try? JSONDecoder().decode(StructuredPayload.self, from: json),
              payload.kind == task.kind.rawValue
        else { throw OpenAICompatibleSelectionAIError.invalidStructuredOutput }

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

    private static func outputText(from root: [String: Any]) -> String? {
        if let direct = root["output_text"] as? String, !direct.isEmpty { return direct }
        guard let output = root["output"] as? [[String: Any]] else { return nil }
        let texts = output.flatMap { item -> [String] in
            guard item["type"] as? String == "message",
                  let content = item["content"] as? [[String: Any]]
            else { return [] }
            return content.compactMap { block in
                guard block["type"] as? String == "output_text" else { return nil }
                return block["text"] as? String
            }
        }
        return texts.isEmpty ? nil : texts.joined(separator: "\n")
    }

    private static func normalizedJSONText(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("```"), trimmed.hasSuffix("```") else { return trimmed }
        var lines = trimmed.split(separator: "\n", omittingEmptySubsequences: false)
        if !lines.isEmpty { lines.removeFirst() }
        if !lines.isEmpty { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    private static func providerErrorMessage(from data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = root["error"] as? [String: Any],
              let message = error["message"] as? String
        else { return nil }
        return String(message.prefix(240))
    }

    private static func prompt(for task: SelectionAITask) -> String {
        let common = "只分析用户提供的截图选区。不要猜测选区外的上下文。"
        switch task {
        case .explain:
            return "\(common) 用中文解释画面内容；primary 和 markdown 都给出完整 Markdown 说明，其余可空字段返回 null。"
        case let .translate(targetLanguage):
            return "\(common) 识别画面文字并翻译为 \(targetLanguage)，保留专业术语、公式和段落；primary 只放译文，并填写语言字段。"
        case .formulaToLaTeX:
            return "\(common) 识别其中的数学或化学公式；primary 只返回可复制的 LaTeX 源码，不加代码围栏。"
        case .extractTable:
            return "\(common) 按视觉行列提取表格；primary 与 markdown 放完整 Markdown 表格，csv 放符合 RFC 4180 的 CSV。"
        }
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
