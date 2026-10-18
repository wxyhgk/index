import XCTest
import GRDB
import CoreGraphics
@testable import IndexApp

/// 连接真实群晖的集成测试（需要网络与私密凭据）。
///
/// **默认跳过**：只有同时设置下面三个环境变量时才真正连服务器。
/// 凭据不再写进源码 —— 历史上这里硬编码过账号密码，已从 HEAD 移除。
///
/// ```bash
/// export INDEX_WEBDAV_TEST_URL="http://nas.local:5005/webdav"
/// export INDEX_WEBDAV_TEST_USER="<user>"
/// export INDEX_WEBDAV_TEST_PASSWORD="<password>"
/// export INDEX_WEBDAV_TEST_PATH="index"   # 可选，默认 index
/// swift test --filter WebDAVClientLiveTests
/// ```
///
/// 跳过策略：
/// - 没配环境变量 → 整组跳过（`check.sh` 与 CI 不受影响）。
/// - 服务器不可达（断网、NAS 关机）→ 整组跳过，避免门禁报假红。
/// - 认证失败、路径 404 等「服务器在线」的错误**不跳过**，照常以测试失败暴露。
final class WebDAVClientLiveTests: XCTestCase {

    private enum LiveConfig {

        /// 从环境变量读配置；缺任何一项都返回 nil。
        static var resolved: WebDAVConfig? {
            let env = ProcessInfo.processInfo.environment
            guard let url = env["INDEX_WEBDAV_TEST_URL"], !url.isEmpty,
                  let user = env["INDEX_WEBDAV_TEST_USER"], !user.isEmpty,
                  let password = env["INDEX_WEBDAV_TEST_PASSWORD"], !password.isEmpty
            else { return nil }
            let path = env["INDEX_WEBDAV_TEST_PATH"].flatMap { $0.isEmpty ? nil : $0 } ?? "index"
            return WebDAVConfig(baseURL: url, username: user, password: password, subPath: path)
        }
    }

    /// 取可用配置。未配置或服务器不可达时抛 `XCTSkip`。
    ///
    /// 连通性探测用一次 Depth:0 PROPFIND（与真实请求同一条 SCK 之外的网络路径），
    /// 失败时区分「网络不可达」与「服务器回应了错误」：前者跳过，后者交给测试断言。
    private func requireConfiguredServer() async throws -> WebDAVConfig {
        guard let config = LiveConfig.resolved else {
            throw XCTSkip("未设置 INDEX_WEBDAV_TEST_URL/USER/PASSWORD，跳过真实 WebDAV 集成测试")
        }
        do {
            _ = try await WebDAVClient(config: config).propfind(path: "")
        } catch is URLError {
            throw XCTSkip("WebDAV 服务器不可达，跳过真实集成测试")
        } catch {
            // 服务器在线但返回非 207（认证、路径不存在等）：让具体测试自己报错。
        }
        return config
    }

    private func makeClient(_ config: WebDAVConfig) -> WebDAVClient {
        WebDAVClient(config: config)
    }

    /// 同步根目录在 WebDAV 上的显示名（如 `index`）。
    private func remoteRootName(_ config: WebDAVConfig) -> String {
        config.subPath.split(separator: "/").last.map(String.init) ?? config.subPath
    }

    // MARK: - 端到端备份测试

    func testBackupEndToEnd() async throws {
        let config = try await requireConfiguredServer()

        // 1. 建临时数据库 + 临时目录
        let database = try DatabaseQueue()
        try AppDatabase.migrator.migrate(database)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sync-e2e-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = await ShotStore(rootDirectory: root, database: database)

        // 2. 插入一条 shot（带原图）
        let image = try makeImage(gray: 0.5)
        let metadata = CaptureMetadata()
        let shot = try await store.save(image: image, metadata: metadata)
        print("插入 shot: id=\(shot.id ?? -1), sha256=\(shot.sha256)")

        // 3. 跑 backup
        let engine = SyncEngine(
            config: config,
            database: database,
            rootDirectory: root
        )
        let result = try await engine.backup()
        print("备份结果: \(result.summary)")
        if !result.errors.isEmpty {
            print("错误（前 5 个）:")
            for e in result.errors.prefix(5) { print("  \(e)") }
        }

        // 4. 断言（增量逻辑：第二次跑时原图已存在会被跳过）
        let hasHTTPErrors = result.errors.contains { $0.contains("HTTP") || $0.contains("403") || $0.contains("404") }
        XCTAssertFalse(hasHTTPErrors, "存在 HTTP 错误：\(result.errors.prefix(3))")
        XCTAssertGreaterThanOrEqual(result.filesUploaded + result.filesSkipped, 2,
                                   "至少处理 manifest + 1 个原图（上传或跳过）")
    }

    private func makeImage(gray: CGFloat) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: 8,
            height: 8,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: gray, green: gray, blue: gray, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        return try XCTUnwrap(context.makeImage())
    }

    func testPropfindRoot() async throws {
        let config = try await requireConfiguredServer()
        let resource = try await makeClient(config).propfind(path: "")
        print("PROPFIND: name=\(resource.name), isDir=\(resource.isDirectory)")
        XCTAssertEqual(resource.name, remoteRootName(config))
        XCTAssertTrue(resource.isDirectory)
    }

    func testListRoot() async throws {
        let config = try await requireConfiguredServer()
        let resources = try await makeClient(config).list(path: "")
        print("LIST: \(resources.count) 个资源")
        for r in resources {
            print("  - \(r.name) (dir: \(r.isDirectory))")
        }
        XCTAssertFalse(resources.isEmpty)
    }

    func testMkcolAndPut() async throws {
        let config = try await requireConfiguredServer()
        let client = makeClient(config)
        let dir = "livetest-\(Int(Date().timeIntervalSince1970))"

        // MKCOL
        try await client.mkcol(path: dir)
        print("MKCOL \(dir): OK")

        // PUT 到子目录
        let data = Data("hello webdav".utf8)
        let etag = try await client.put(path: "\(dir)/hello.txt", data: data, contentType: "text/plain")
        print("PUT \(dir)/hello.txt: OK, etag=\(etag)")

        // GET 回来
        let fetched = try await client.get(path: "\(dir)/hello.txt")
        XCTAssertEqual(String(data: fetched, encoding: .utf8), "hello webdav")
        print("GET: OK")

        // DELETE
        try await client.delete(path: "\(dir)/hello.txt")
        print("DELETE: OK")
    }

    func testPutFileStreaming() async throws {
        let config = try await requireConfiguredServer()
        let client = makeClient(config)
        let dir = "livetest-stream-\(Int(Date().timeIntervalSince1970))"

        // MKCOL
        try await client.mkcol(path: dir)

        // 创建 11MB 临时文件（超过 10MB 阈值，走 putFile 流式路径）
        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("stream-test-\(UUID().uuidString).bin")
        let bigData = Data(repeating: 0xAB, count: 11 * 1024 * 1024)
        try bigData.write(to: tempFile)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        // 流式上传
        try await client.putFile(path: "\(dir)/big.bin", fileURL: tempFile, contentType: "application/octet-stream")
        print("PUTFile \(dir)/big.bin (11MB): OK")

        // GET 回来验证大小
        let fetched = try await client.get(path: "\(dir)/big.bin")
        XCTAssertEqual(fetched.count, 11 * 1024 * 1024)
        print("GET: OK, \(fetched.count) bytes")

        // DELETE
        try await client.delete(path: "\(dir)/big.bin")
        print("DELETE: OK")
    }

    func testCollectRemoteFiles() async throws {
        let config = try await requireConfiguredServer()
        // 模拟 SyncEngine.collectRemoteFiles 的逻辑
        let client = makeClient(config)
        var paths: Set<String> = []
        try await collect(path: "", rootName: remoteRootName(config), into: &paths, client: client)
        print("远端文件集合: \(paths.count) 个文件")
        for p in paths.sorted().prefix(10) {
            print("  \(p)")
        }
    }

    private func collect(
        path: String,
        rootName: String,
        into paths: inout Set<String>,
        client: WebDAVClient
    ) async throws {
        let resources = try await client.list(path: path)
        // Depth:1 PROPFIND 会返回目录自身（不只是根目录），每层都跳过
        let currentDirName: String
        if path.isEmpty {
            currentDirName = rootName
        } else {
            currentDirName = path.split(separator: "/").last.map(String.init) ?? ""
        }
        for resource in resources {
            if resource.isDirectory && resource.name == currentDirName {
                continue
            }
            let fullPath = path.isEmpty ? resource.name : "\(path)/\(resource.name)"
            if resource.isDirectory {
                try await collect(path: fullPath, rootName: rootName, into: &paths, client: client)
            } else {
                paths.insert(fullPath)
            }
        }
    }
}
