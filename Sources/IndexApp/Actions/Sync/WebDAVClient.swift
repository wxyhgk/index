import Foundation

/// WebDAV 客户端：封装 PROPFIND / PUT / GET / DELETE / MKCOL。
///
/// 群晖 WebDAV 端点形如 `http://ds720.local:5005/webdav`，
/// 认证用 Basic（用户名 + 密码）。
///
/// 本类不持有 AppSettings，配置由调用方传入（和 ImageUploader 同模式）。

struct WebDAVConfig: Equatable {
    /// 服务器根地址，如 `http://ds720.local:5005/webdav`
    var baseURL: String
    var username: String
    var password: String
    /// 同步子目录（相对 webdav 根），如 `index`
    var subPath: String = "index"

    var fullBaseURL: URL? {
        URL(string: baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL)
    }

    var syncURL: URL? {
        guard let base = fullBaseURL else { return nil }
        return base.appendingPathComponent(subPath)
    }
}

enum WebDAVError: LocalizedError {
    case invalidURL
    case httpError(code: Int, message: String)
    case networkError(String)
    case notFound(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "WebDAV 地址无效"
        case .httpError(let code, let msg):
            return "HTTP \(code)：\(msg)"
        case .networkError(let detail):
            return "网络错误：\(detail)"
        case .notFound(let path):
            return "远端不存在：\(path)"
        }
    }
}

/// 文件/目录信息（PROPFIND 返回）。
struct WebDAVResource: Equatable {
    let name: String
    let isDirectory: Bool
    let contentLength: Int64?
    let lastModified: Date?
    let etag: String?
}

final class WebDAVClient {
    private let config: WebDAVConfig
    private let session: URLSession

    init(config: WebDAVConfig) {
        self.config = config
        let delegate = TrustAllTLSDelegate()
        let descriptor = OperationQueue()
        descriptor.maxConcurrentOperationCount = 4
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 120
        self.session = URLSession(configuration: cfg, delegate: delegate, delegateQueue: nil)
        // 保持 delegate 强引用（URLSession 弱持有）
        self.delegate = delegate
    }

    private let delegate: TrustAllTLSDelegate

    // MARK: - 认证

    private var authHeader: String {
        let credential = "\(config.username):\(config.password)"
        let data = Data(credential.utf8)
        return "Basic \(data.base64EncodedString())"
    }

    // MARK: - 请求构造

    private func makeRequest(method: String, path: String, headers: [String: String] = [:]) throws -> URLRequest {
        guard let base = config.syncURL else { throw WebDAVError.invalidURL }
        let url: URL
        if path.isEmpty {
            // 请求同步根目录：确保带尾部斜杠（群晖 WebDAV 对目录路径要求 /）
            let urlString = base.absoluteString.hasSuffix("/")
                ? base.absoluteString
                : base.absoluteString + "/"
            url = URL(string: urlString) ?? base
        } else {
            url = base.appendingPathComponent(path)
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(authHeader, forHTTPHeaderField: "Authorization")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        return request
    }

    // MARK: - PROPFIND（获取资源信息）

    /// 获取指定路径的资源信息。路径为空时获取同步根目录。
    func propfind(path: String = "") async throws -> WebDAVResource {
        var request = try makeRequest(method: "PROPFIND", path: path, headers: [
            "Depth": "0",
            "Content-Type": "application/xml"
        ])
        request.httpBody = Self.propfindBody

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw WebDAVError.networkError("非 HTTP 响应")
        }
        guard http.statusCode == 207 else {
            throw WebDAVError.httpError(code: http.statusCode, message: String(data: data, encoding: .utf8) ?? "")
        }
        return try Self.parsePropfindResponse(data: data, path: path)
    }

    /// 列出目录下的所有子资源。
    func list(path: String = "") async throws -> [WebDAVResource] {
        var request = try makeRequest(method: "PROPFIND", path: path, headers: [
            "Depth": "1",
            "Content-Type": "application/xml"
        ])
        request.httpBody = Self.propfindBody

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw WebDAVError.networkError("非 HTTP 响应")
        }
        guard http.statusCode == 207 else {
            throw WebDAVError.httpError(code: http.statusCode, message: String(data: data, encoding: .utf8) ?? "")
        }
        return try Self.parsePropfindList(data: data)
    }

    // MARK: - MKCOL（创建目录）

    func mkcol(path: String) async throws {
        let request = try makeRequest(method: "MKCOL", path: path)
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw WebDAVError.networkError("非 HTTP 响应")
        }
        // 201 = 创建成功，405 = 已存在（幂等）
        guard http.statusCode == 201 || http.statusCode == 405 else {
            throw WebDAVError.httpError(code: http.statusCode, message: "MKCOL \(path)")
        }
    }

    // MARK: - PUT（上传文件）

    @discardableResult
    func put(path: String, data: Data, contentType: String = "application/octet-stream") async throws -> String {
        var request = try makeRequest(method: "PUT", path: path, headers: [
            "Content-Type": contentType
        ])
        request.httpBody = data

        let (responseData, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw WebDAVError.networkError("非 HTTP 响应")
        }
        guard http.statusCode == 201 || http.statusCode == 204 else {
            throw WebDAVError.httpError(code: http.statusCode, message: String(data: responseData, encoding: .utf8) ?? "")
        }
        return http.value(forHTTPHeaderField: "ETag") ?? ""
    }

    /// 从磁盘文件流式上传（不读入内存，适合大文件）。
    @discardableResult
    func putFile(path: String, fileURL: URL, contentType: String = "application/octet-stream") async throws -> String {
        var request = try makeRequest(method: "PUT", path: path, headers: [
            "Content-Type": contentType
        ])
        let (responseData, response) = try await session.upload(for: request, fromFile: fileURL)
        guard let http = response as? HTTPURLResponse else {
            throw WebDAVError.networkError("非 HTTP 响应")
        }
        guard http.statusCode == 201 || http.statusCode == 204 else {
            throw WebDAVError.httpError(code: http.statusCode, message: String(data: responseData, encoding: .utf8) ?? "")
        }
        return http.value(forHTTPHeaderField: "ETag") ?? ""
    }

    // MARK: - GET（下载文件）

    func get(path: String) async throws -> Data {
        let request = try makeRequest(method: "GET", path: path)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw WebDAVError.networkError("非 HTTP 响应")
        }
        guard http.statusCode == 200 else {
            if http.statusCode == 404 {
                throw WebDAVError.notFound(path)
            }
            throw WebDAVError.httpError(code: http.statusCode, message: "GET \(path)")
        }
        return data
    }

    // MARK: - DELETE

    func delete(path: String) async throws {
        let request = try makeRequest(method: "DELETE", path: path)
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw WebDAVError.networkError("非 HTTP 响应")
        }
        guard http.statusCode == 204 || http.statusCode == 404 else {
            throw WebDAVError.httpError(code: http.statusCode, message: "DELETE \(path)")
        }
    }

    // MARK: - 测试连接

    /// 验证服务器可达 + 认证正确。
    func testConnection() async throws -> String {
        let requestURL = config.syncURL?.absoluteString ?? "(无效地址)"
        do {
            let resource = try await propfind(path: "")
            let kind = resource.isDirectory ? "目录" : "文件"
            return "连接成功：\(resource.name)（\(kind)）\n请求地址：\(requestURL)"
        } catch WebDAVError.httpError(let code, let msg) {
            throw WebDAVError.httpError(code: code, message: "请求 \(requestURL)\n\(msg)")
        }
    }

    // MARK: - 递归列出所有文件

    /// 递归遍历同步根目录，返回所有文件路径集合（不含目录）。
    /// 用于增量上传时跳过远端已存在的文件。
    func listAllFiles() async throws -> Set<String> {
        var paths: Set<String> = []
        try await collectFiles(path: "", into: &paths)
        return paths
    }

    private func collectFiles(path: String, into paths: inout Set<String>) async throws {
        let resources = try await list(path: path)
        // Depth:1 PROPFIND 会返回目录自身，跳过
        let currentDirName: String
        if path.isEmpty {
            currentDirName = config.subPath.split(separator: "/").last.map(String.init) ?? ""
        } else {
            currentDirName = path.split(separator: "/").last.map(String.init) ?? ""
        }
        for resource in resources {
            if resource.isDirectory && resource.name == currentDirName {
                continue
            }
            let fullPath = path.isEmpty ? resource.name : "\(path)/\(resource.name)"
            if resource.isDirectory {
                try await collectFiles(path: fullPath, into: &paths)
            } else {
                paths.insert(fullPath)
            }
        }
    }

    // MARK: - PROPFIND XML 解析

    private static let propfindBody: Data = """
        <?xml version="1.0" encoding="utf-8"?>
        <propfind xmlns="DAV:">
            <prop>
                <displayname/>
                <resourcetype/>
                <getcontentlength/>
                <getlastmodified/>
                <getetag/>
            </prop>
        </propfind>
        """.data(using: .utf8)!

    private static func parsePropfindResponse(data: Data, path: String) throws -> WebDAVResource {
        let resources = try parsePropfindList(data: data)
        // Depth:0 只返回自身
        guard let resource = resources.first else {
            throw WebDAVError.httpError(code: 207, message: "PROPFIND 无结果")
        }
        return resource
    }

    private static func parsePropfindList(data: Data) throws -> [WebDAVResource] {
        let parser = XMLParser(data: data)
        let parser2 = PropfindXMLParser()
        parser.delegate = parser2
        parser.parse()
        if let error = parser2.error {
            throw WebDAVError.httpError(code: 207, message: "XML 解析失败: \(error.localizedDescription)")
        }
        return parser2.resources
    }
}

// MARK: - PROPFIND XML 解析器

private final class PropfindXMLParser: NSObject, XMLParserDelegate {
    var resources: [WebDAVResource] = []
    var error: Error?

    private var currentName: String?
    private var currentHref: String?
    private var currentIsDirectory = false
    private var currentLength: Int64?
    private var currentLastModified: Date?
    private var currentEtag: String?
    private var inResponse = false
    private var currentElement: String?

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String] = [:]) {
        // name 带命名空间前缀（如 "D:response"、"lp1:getetag"），取 ":" 后的本地名
        let localName = name.contains(":") ? String(name.split(separator: ":").last!) : name
        switch localName {
        case "response":
            inResponse = true
            currentName = nil
            currentHref = nil
            currentIsDirectory = false
            currentLength = nil
            currentLastModified = nil
            currentEtag = nil
        case "href":
            currentElement = "href"
        case "displayname":
            currentElement = "displayname"
        case "collection":
            currentIsDirectory = true
        case "getcontentlength":
            currentElement = "getcontentlength"
        case "getlastmodified":
            currentElement = "getlastmodified"
        case "getetag":
            currentElement = "getetag"
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        switch currentElement {
        case "href":
            currentHref = string.trimmingCharacters(in: .whitespaces)
        case "displayname":
            if !string.isEmpty {
                currentName = string
            }
        case "getcontentlength":
            currentLength = Int64(string.trimmingCharacters(in: .whitespaces))
        case "getlastmodified":
            let formatter = DateFormatter()
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            formatter.locale = Locale(identifier: "en_US_POSIX")
            currentLastModified = formatter.date(from: string.trimmingCharacters(in: .whitespaces))
        case "getetag":
            currentEtag = string.trimmingCharacters(in: .whitespaces)
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName qName: String?) {
        let localName = name.contains(":") ? String(name.split(separator: ":").last!) : name
        if localName == "response", inResponse {
            inResponse = false
            // 群晖对目录的 displayname 返回空，从 href 提取名称
            let displayName: String
            if let name = currentName, !name.isEmpty {
                displayName = name
            } else if let href = currentHref {
                // href 形如 "/webdav/index/" → 取最后一段
                let trimmed = href.hasSuffix("/") ? String(href.dropLast()) : href
                displayName = trimmed.split(separator: "/").last.map(String.init) ?? href
            } else {
                displayName = ""
            }
            resources.append(WebDAVResource(
                name: displayName,
                isDirectory: currentIsDirectory,
                contentLength: currentLength,
                lastModified: currentLastModified,
                etag: currentEtag
            ))
        }
        currentElement = nil
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        self.error = parseError
    }
}

// MARK: - TLS 信任（群晖自签证书场景）

private final class TrustAllTLSDelegate: NSObject, URLSessionDelegate {
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
