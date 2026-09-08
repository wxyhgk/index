import Foundation

/// 一次上传所需的全部配置。由调用方（App 层动作）从 AppSettings 组装，
/// Platform 层自己不认识任何配置来源。
struct UploadConfig {
    /// 图床接口地址。
    let endpoint: String
    /// multipart 里图片文件的字段名，如 "file"。
    let fieldName: String
    /// 自定义请求头原文，每行一条 "Key: Value"，解析时容错跳过坏行。
    let headersText: String
    /// 从 JSON 响应取链接的点分路径（如 "data.url"）。空 = 整个响应体即链接。
    let responsePath: String
}

enum UploadError: LocalizedError {
    case notConfigured
    case invalidEndpoint(String)
    case encodeFailed
    case network(Error)
    case httpFailure(status: Int, body: String)
    case parseFailed(path: String, body: String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "尚未配置图床。请到「设置 → 上传」填写接口地址。"
        case .invalidEndpoint(let url):
            return "接口地址无效：\(url)"
        case .encodeFailed:
            return "无法把截图编码为 PNG。"
        case .network(let error):
            return "网络请求失败：\(error.localizedDescription)"
        case .httpFailure(let status, let body):
            return "服务器返回 HTTP \(status)：\(body.prefix(200))"
        case .parseFailed(let path, let body):
            return "按路径「\(path)」没能从响应里取到链接。响应开头：\(body.prefix(200))"
        }
    }
}

/// 通用自定义 HTTP 图床上传器（uPic / PicGo 自定义 API 同款思路）：
/// multipart/form-data POST 一张图，按点分路径从 JSON 响应里挖出链接。
/// 不做 S3 等云厂商签名 —— 那类接口请套一层 Workers / PicGo 兼容网关。
enum ImageUploader {

    /// 上传请求超时（秒）。
    private static let uploadTimeout: TimeInterval = 30

    /// 上传一张 PNG，返回图床链接。
    static func upload(png: Data, filename: String, config: UploadConfig) async throws -> String {
        let endpoint = config.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !endpoint.isEmpty else { throw UploadError.notConfigured }
        guard let url = URL(string: endpoint), url.scheme?.hasPrefix("http") == true else {
            throw UploadError.invalidEndpoint(endpoint)
        }

        var request = URLRequest(url: url, timeoutInterval: uploadTimeout)
        request.httpMethod = "POST"
        for (key, value) in parseHeaders(config.headersText) {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let boundary = "Index-\(UUID().uuidString)"
        request.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )

        let fieldName = config.fieldName.isEmpty ? "file" : config.fieldName
        var body = Data()
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data(
            "Content-Disposition: form-data; name=\"\(fieldName)\"; filename=\"\(filename)\"\r\n"
                .utf8
        ))
        body.append(Data("Content-Type: image/png\r\n\r\n".utf8))
        body.append(png)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        request.httpBody = body

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw UploadError.network(error)
        }

        let bodyText = String(data: data, encoding: .utf8) ?? ""
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw UploadError.httpFailure(status: http.statusCode, body: bodyText)
        }

        return try extractLink(from: data, path: config.responsePath)
    }

    /// 每行一条 "Key: Value"。没有冒号或键为空的行直接跳过，不报错。
    static func parseHeaders(_ text: String) -> [(String, String)] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            guard let colon = line.firstIndex(of: ":") else { return nil }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { return nil }
            return (key, value)
        }
    }

    /// 按点分路径从 JSON 里逐级取字符串。路径为空时整个响应体就是链接。
    /// 不支持数组下标 —— 中途遇到非字典或缺键都按解析失败报。
    static func extractLink(from data: Data, path: String) throws -> String {
        let bodyText = String(data: data, encoding: .utf8) ?? ""
        let trimmedPath = path.trimmingCharacters(in: .whitespaces)
        guard !trimmedPath.isEmpty else {
            let link = bodyText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !link.isEmpty else {
                throw UploadError.parseFailed(path: "(整个响应体)", body: bodyText)
            }
            return link
        }

        guard let root = try? JSONSerialization.jsonObject(with: data) else {
            throw UploadError.parseFailed(path: trimmedPath, body: bodyText)
        }

        var node: Any = root
        for key in trimmedPath.split(separator: ".") {
            guard let dict = node as? [String: Any], let next = dict[String(key)] else {
                throw UploadError.parseFailed(path: trimmedPath, body: bodyText)
            }
            node = next
        }

        if let link = node as? String, !link.isEmpty { return link }
        throw UploadError.parseFailed(path: trimmedPath, body: bodyText)
    }
}
