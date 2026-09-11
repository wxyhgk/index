import Foundation
import GRDB

/// WebDAV 同步引擎：备份（上传）+ 恢复（下载）。
///
/// v1 策略：
/// - 备份 = 本地导出 PortableLibrary → 上传 manifest + 文件（跳过远端已存在的）
/// - 恢复 = 下载远端 manifest + 文件 → 导入本地数据库
///
/// 不做双向增量合并（冲突处理留 v2）。

final class SyncEngine {
    private let client: WebDAVClient
    private let config: WebDAVConfig
    private let database: any DatabaseWriter
    private let rootDirectory: URL
    private let fileManager: FileManager

    init(
        config: WebDAVConfig,
        database: any DatabaseWriter,
        rootDirectory: URL,
        fileManager: FileManager = .default
    ) {
        self.client = WebDAVClient(config: config)
        self.config = config
        self.database = database
        self.rootDirectory = rootDirectory
        self.fileManager = fileManager
    }

    // MARK: - 测试连接

    func testConnection() async throws -> String {
        try await client.testConnection()
    }

    // MARK: - 备份（上传）

    func backup(onProgress: ((SyncProgress) -> Void)? = nil) async throws -> SyncResult {
        var result = SyncResult()
        let progress: (String, Int, Int) -> Void = { phase, current, total in
            onProgress?(SyncProgress(phase: phase, current: current, total: total))
        }

        // 1. 清理原图缺失的 image shot
        progress("清理缺失记录", 0, 0)
        let cleaned = try await cleanupMissingOriginals()
        if cleaned > 0 {
            result.errors.append("清理 \(cleaned) 条原图缺失的记录")
        }

        // 2. 确保远端目录存在
        progress("连接服务器", 0, 0)
        try await ensureRemoteDirectory()

        // 3. 导出 PortableLibrary 到临时目录
        progress("导出本地图库", 0, 0)
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("index-sync-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: staging) }

        let exporter = PortableLibraryExporter(
            database: database,
            rootDirectory: rootDirectory
        )
        _ = try await exporter.export(to: staging)

        // 4. 扫描远端已有文件
        progress("扫描远端文件", 0, 0)
        let remoteFiles = try? await client.listAllFiles()

        // 5. 创建远端子目录（含嵌套）
        let files = try listFiles(in: staging)
        let directories = Self.collectDirectories(from: files)
        let sortedDirs = directories.sorted(by: { $0.split(separator: "/").count < $1.split(separator: "/").count })
        for (i, dir) in sortedDirs.enumerated() {
            progress("创建目录", i + 1, sortedDirs.count)
            try await client.mkcol(path: dir)
        }

        // 6. 上传文件（小文件走内存，大文件走磁盘流式，避免大文件撑爆内存）
        let uploadFiles = files.filter { $0.relativePath != "manifest.json" }
        var processed = 0
        for file in uploadFiles {
            processed += 1
            progress("上传文件", processed, uploadFiles.count)
            if let remoteFiles, remoteFiles.contains(file.relativePath) {
                result.filesSkipped += 1
                continue
            }
            do {
                let size = (try? file.url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                if size > 10 * 1024 * 1024 {
                    // >10MB：从磁盘流式上传，不读入内存
                    try await client.putFile(path: file.relativePath, fileURL: file.url, contentType: file.contentType)
                } else {
                    let data = try Data(contentsOf: file.url)
                    try await client.put(path: file.relativePath, data: data, contentType: file.contentType)
                }
                result.filesUploaded += 1
            } catch {
                result.errors.append("\(file.relativePath): \(error.localizedDescription)")
            }
        }

        // 7. 最后上传 manifest.json（事务性：文件全传完才标记备份完成）
        //    中途失败时远端保留上次的完整 manifest，restore 不会拿到半套备份
        progress("上传 manifest", 0, 1)
        let manifestData = try Data(contentsOf: staging.appendingPathComponent("manifest.json"))
        try await client.put(path: "manifest.json", data: manifestData, contentType: "application/json")
        result.filesUploaded += 1

        return result
    }

    // MARK: - 恢复（下载）

    func restore() async throws -> SyncResult {
        var result = SyncResult()

        // 1. 下载 manifest.json
        let manifestData = try await client.get(path: "manifest.json")
        let manifest = try PortableLibraryCoding.makeDecoder()
            .decode(PortableLibraryManifest.self, from: manifestData)

        // 2. 下载所有文件到临时目录
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("index-restore-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }

        let filePaths = Self.collectFilePaths(from: manifest)
        for path in filePaths {
            do {
                let data = try await client.get(path: path)
                let localURL = staging.appendingPathComponent(path)
                try fileManager.createDirectory(
                    at: localURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try data.write(to: localURL)
                result.filesDownloaded += 1
            } catch WebDAVError.notFound {
                result.errors.append("\(path): 远端文件缺失")
            }
        }

        // 3. 写 manifest.json 到临时目录
        try manifestData.write(to: staging.appendingPathComponent("manifest.json"))

        // 4. 导入本地数据库
        let importer = PortableLibraryImporter(
            writer: database,
            rootDirectory: staging
        )
        let report = try await importer.importLibrary(at: staging)
        result.importReport = report.summary

        return result
    }

    // MARK: - 辅助

    /// 清理 image 类型但原图文件不存在的 shot（markdown 便签跳过）。
    private func cleanupMissingOriginals() async throws -> Int {
        let records: [(id: Int64, fileName: String)] = try await database.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, sha256 || '.' || COALESCE(originalExtension, 'png') AS fileName
                FROM shot
                WHERE contentKind != 'markdown'
                """).compactMap { row in
                guard let id = row["id"] as Int64?,
                      let fileName = row["fileName"] as String? else { return nil }
                return (id, fileName)
            }
        }
        let originalsDir = rootDirectory.appendingPathComponent("originals", isDirectory: true)
        var missing: [Int64] = []
        for record in records {
            let url = originalsDir.appendingPathComponent(record.fileName)
            if !fileManager.fileExists(atPath: url.path) {
                missing.append(record.id)
            }
        }
        guard !missing.isEmpty else { return 0 }
        try await database.write { db in
            for id in missing {
                try db.execute(sql: "DELETE FROM shot WHERE id = ?", arguments: [id])
            }
        }
        return missing.count
    }

    /// 确保远端同步目录存在（逐层 MKCOL）。
    private func ensureRemoteDirectory() async throws {
        do {
            _ = try await client.propfind(path: "")
        } catch WebDAVError.httpError(let code, _) where code == 404 {
            let components = config.subPath.split(separator: "/").map(String.init)
            var current = ""
            for component in components {
                current = current.isEmpty ? component : "\(current)/\(component)"
                try await client.mkcol(path: current)
            }
        }
    }

    // MARK: - 文件枚举

    private struct LocalFile {
        let url: URL
        let relativePath: String
        let contentType: String
    }

    private func listFiles(in directory: URL) throws -> [LocalFile] {
        var files: [LocalFile] = []
        let resolvedDir = directory.resolvingSymlinksInPath().path
        guard let enumerator = fileManager.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return []
        }
        for case let url as URL in enumerator {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDirectory { continue }
            let resolvedURL = url.resolvingSymlinksInPath()
            let relative = resolvedURL.path.replacingOccurrences(of: resolvedDir + "/", with: "")
            let ext = url.pathExtension.lowercased()
            let contentType: String
            switch ext {
            case "png": contentType = "image/png"
            case "jpg", "jpeg": contentType = "image/jpeg"
            case "svg": contentType = "image/svg+xml"
            case "json": contentType = "application/json"
            default: contentType = "application/octet-stream"
            }
            files.append(LocalFile(url: url, relativePath: relative, contentType: contentType))
        }
        return files
    }

    // MARK: - 静态工具

    /// 从文件列表中提取所有中间目录（含嵌套）。
    private static func collectDirectories(from files: [LocalFile]) -> Set<String> {
        var directories: Set<String> = []
        for file in files {
            var current = ""
            for component in file.relativePath.split(separator: "/").dropLast() {
                current = current.isEmpty ? String(component) : "\(current)/\(component)"
                directories.insert(current)
            }
        }
        return directories
    }

    /// 从 manifest 中提取所有需要下载的文件路径。
    static func collectFilePaths(from manifest: PortableLibraryManifest) -> Set<String> {
        var paths: Set<String> = []
        for shot in manifest.shots {
            paths.insert(shot.original.relativePath)
            for asset in shot.assets {
                if let path = asset.relativePath {
                    paths.insert(path)
                }
            }
        }
        for item in manifest.clipboard {
            if let path = item.asset?.relativePath {
                paths.insert(path)
            }
        }
        return paths
    }
}
