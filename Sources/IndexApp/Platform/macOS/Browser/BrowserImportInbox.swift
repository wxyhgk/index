import Foundation

/// Edge Native Messaging host 与 Index 之间的磁盘交接协议。
///
/// URL 命令只携带 UUID，不接受外部传入的绝对路径；图片和元数据必须位于固定收件箱的
/// `<UUID>/` 子目录中。这样浏览器扩展不能借 `macshot://` 读取用户磁盘上的任意文件。
enum BrowserImportInbox {

    struct Completion: Codable, Equatable, Sendable {
        let ok: Bool
        let fileName: String?
        let error: String?
    }

    struct Metadata: Codable, Equatable, Sendable {
        let schemaVersion: Int
        let imageFile: String
        let fileName: String
        let mimeType: String
        let pageURL: String?
        let pageTitle: String?
        let imageURL: String?
    }

    struct Item: Equatable, Sendable {
        let id: UUID
        let imageURL: URL
        let metadata: Metadata
    }

    enum InboxError: LocalizedError, Equatable {
        case invalidID
        case missingItem
        case invalidMetadata
        case unsafeImagePath
        case invalidImageFile

        var errorDescription: String? {
            switch self {
            case .invalidID: return "浏览器导入编号无效。"
            case .missingItem: return "找不到浏览器发送的图片，可能已经过期。"
            case .invalidMetadata: return "浏览器图片元数据无效。"
            case .unsafeImagePath: return "浏览器图片路径不安全。"
            case .invalidImageFile: return "浏览器图片文件无效。"
            }
        }
    }

    static func defaultRootDirectory() -> URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Index", isDirectory: true)
            .appendingPathComponent("browser-inbox", isDirectory: true)
    }

    static func item(id rawID: String, rootDirectory: URL? = nil) throws -> Item {
        guard let id = UUID(uuidString: rawID) else { throw InboxError.invalidID }
        let root = (rootDirectory ?? defaultRootDirectory()).standardizedFileURL
        let directory = root.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else {
            throw InboxError.missingItem
        }

        let metadataURL = directory.appendingPathComponent("metadata.json", isDirectory: false)
        guard let data = try? Data(contentsOf: metadataURL),
              let metadata = try? JSONDecoder().decode(Metadata.self, from: data),
              metadata.schemaVersion == 1,
              !metadata.fileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw InboxError.invalidMetadata
        }

        let imageFile = metadata.imageFile.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !imageFile.isEmpty,
              imageFile == URL(fileURLWithPath: imageFile).lastPathComponent
        else {
            throw InboxError.unsafeImagePath
        }
        let imageURL = directory.appendingPathComponent(imageFile, isDirectory: false).standardizedFileURL
        guard imageURL.deletingLastPathComponent() == directory.standardizedFileURL else {
            throw InboxError.unsafeImagePath
        }

        let values = try? imageURL.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
        ])
        guard values?.isRegularFile == true,
              values?.isSymbolicLink != true,
              let size = values?.fileSize,
              size > 0,
              size <= 25 * 1024 * 1024
        else {
            throw InboxError.invalidImageFile
        }
        return Item(id: id, imageURL: imageURL, metadata: metadata)
    }

    static func remove(id: UUID, rootDirectory: URL? = nil) {
        let root = (rootDirectory ?? defaultRootDirectory()).standardizedFileURL
        let directory = root.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
        try? FileManager.default.removeItem(at: directory)
    }

    /// 把真正的入库结果回传给仍在等待的 Native Messaging host。
    /// 结果单独放在 `.results/`，避免删除图片收件箱时一并丢失确认信号。
    static func writeCompletion(
        _ completion: Completion,
        id: UUID,
        rootDirectory: URL? = nil
    ) {
        let root = (rootDirectory ?? defaultRootDirectory()).standardizedFileURL
        let results = root.appendingPathComponent(".results", isDirectory: true)
        let destination = results.appendingPathComponent(
            "\(id.uuidString.lowercased()).json",
            isDirectory: false
        )
        do {
            try FileManager.default.createDirectory(
                at: results,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let data = try JSONEncoder().encode(completion)
            try data.write(to: destination, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: destination.path
            )
        } catch {
            NSLog("[Index] 无法写入浏览器导入结果: \(error.localizedDescription)")
        }
    }
}
