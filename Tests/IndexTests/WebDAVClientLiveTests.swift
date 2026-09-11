import XCTest
import GRDB
import CoreGraphics
@testable import IndexApp

/// 连接真实群晖的集成测试（需要网络）。
/// 跑法：swift test --filter WebDAVClientLiveTests
final class WebDAVClientLiveTests: XCTestCase {

    // MARK: - 端到端备份测试

    func testBackupEndToEnd() async throws {
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
            config: WebDAVConfig(
                baseURL: "http://ds720.local:5005/webdav",
                username: "wxyhgk",
                password: "REDACTED",
                subPath: "index"
            ),
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

    private func makeClient() -> WebDAVClient {
        WebDAVClient(config: WebDAVConfig(
            baseURL: "http://ds720.local:5005/webdav",
            username: "wxyhgk",
            password: "REDACTED",
            subPath: "index"
        ))
    }

    func testPropfindRoot() async throws {
        let client = makeClient()
        let resource = try await client.propfind(path: "")
        print("PROPFIND: name=\(resource.name), isDir=\(resource.isDirectory)")
        XCTAssertEqual(resource.name, "index")
        XCTAssertTrue(resource.isDirectory)
    }

    func testListRoot() async throws {
        let client = makeClient()
        let resources = try await client.list(path: "")
        print("LIST: \(resources.count) 个资源")
        for r in resources {
            print("  - \(r.name) (dir: \(r.isDirectory))")
        }
        XCTAssertFalse(resources.isEmpty)
    }

    func testMkcolAndPut() async throws {
        let client = makeClient()
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
        let client = makeClient()
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
        // 模拟 SyncEngine.collectRemoteFiles 的逻辑
        let client = makeClient()
        var paths: Set<String> = []
        try await collect(path: "", into: &paths, client: client)
        print("远端文件集合: \(paths.count) 个文件")
        for p in paths.sorted().prefix(10) {
            print("  \(p)")
        }
    }

    private func collect(path: String, into paths: inout Set<String>, client: WebDAVClient) async throws {
        let resources = try await client.list(path: path)
        // Depth:1 PROPFIND 会返回目录自身（不只是根目录），每层都跳过
        let currentDirName: String
        if path.isEmpty {
            currentDirName = "index"
        } else {
            currentDirName = path.split(separator: "/").last.map(String.init) ?? ""
        }
        for resource in resources {
            if resource.isDirectory && resource.name == currentDirName {
                continue
            }
            let fullPath = path.isEmpty ? resource.name : "\(path)/\(resource.name)"
            if resource.isDirectory {
                try await collect(path: fullPath, into: &paths, client: client)
            } else {
                paths.insert(fullPath)
            }
        }
    }
}
