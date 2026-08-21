import Foundation
import GRDB

/// Index 与未来 Windows 客户端之间的便携图库契约。
///
/// 这不是运行中的 SQLite 副本：导出器从一个数据库 read snapshot 生成只读清单，
/// 再复制不可变原图与文件附件。Windows 应把它导入自己的本地数据库，不能通过
/// OneDrive 等同步盘让两个进程共同打开 `index.sqlite` / WAL。
struct PortableLibraryManifest: Codable, Equatable {
    static let formatIdentifier = "com.index.portable-library"
    static let currentFormatVersion = 2

    let format: String
    let formatVersion: Int
    let minimumReaderVersion: Int
    let exportedAt: Date
    let producer: PortableLibraryProducer
    let shots: [PortableLibraryShot]
    let collections: [PortableLibraryCollection]
    let clipboard: [PortableLibraryClipboardItem]
}

struct PortableLibraryProducer: Codable, Equatable {
    let name: String
    let version: String?
    /// v1 使用稳定英文值：`macOS` / `windows`。
    let platform: String
}

struct PortableLibraryShot: Codable, Equatable {
    /// 仅在本次导出包内稳定，例如 `shot-42`；不是跨设备同步 UUID。
    let id: String
    let contentHash: String
    let original: PortableLibraryFile
    let capturedAt: Date
    let pixelWidth: Int
    let pixelHeight: Int
    let scale: Double
    let customTitle: String?
    let source: PortableLibrarySource
    let ocrText: String?
    let favorite: Bool
    let tags: [String]
    let category: String?
    let revisions: [PortableLibraryRevision]
    let assets: [PortableLibraryAsset]
}

struct PortableLibraryFile: Codable, Equatable {
    let relativePath: String
    let mediaType: String
    let sha256: String?
}

struct PortableLibrarySource: Codable, Equatable {
    let appName: String?
    let appIdentifier: PortableLibraryAppIdentifier?
    let appVersion: String?
    let appBuild: String?
    let windowTitle: String?
    let url: String?
    let displayName: String?
    let region: PortableLibraryCaptureRegion
}

struct PortableLibraryAppIdentifier: Codable, Equatable {
    /// 当前 macOS 写 `bundle-id`；Windows 将写 `aumid` 或 `executable`。
    let kind: String
    let value: String
}

struct PortableLibraryCaptureRegion: Codable, Equatable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    /// 当前值为 `macos-global-points-bottom-left`。标注图层不使用此坐标，
    /// 它们始终是跨平台的 `image-pixels-top-left`。
    let coordinateSpace: String
}

struct PortableLibraryRevision: Codable, Equatable {
    let id: String
    let parentID: String?
    let createdAt: Date
    let note: String?
    let layers: [Layer]
}

struct PortableLibraryAsset: Codable, Equatable {
    let id: String
    let kind: String
    let schemaVersion: Int
    /// 文件附件复制进包后的位置；内嵌附件或源文件缺失时为 nil。
    let relativePath: String?
    /// 可直接跨平台读取的 UTF-8 文本，例如 XYZ 坐标。
    let textContent: String?
    /// `textContent` 的媒体类型，例如 `chemical/x-xyz`。
    let mediaType: String?
    /// 未定义专用文本契约的内嵌载荷用标准 JSON base64 表示。
    let payload: Data?
    /// 外部文件已经被用户移动/删除时仍保留资产身份，但绝不写入原机器绝对路径。
    let missing: Bool
    let originalFileName: String?
    let createdAt: Date
    let updatedAt: Date
}

struct PortableLibraryCollection: Codable, Equatable {
    let id: String
    let name: String
    let note: String
    let coverShotID: String?
    let createdAt: Date
    let updatedAt: Date
    let sortOrder: Int
    let items: [PortableLibraryCollectionItem]
    let clipboardItems: [PortableLibraryClipboardCollectionItem]
}

struct PortableLibraryCollectionItem: Codable, Equatable {
    let shotID: String
    let addedAt: Date
    let sortOrder: Int
}

/// 剪贴板条目在便携包中的表示。
///
/// 图片/文件条目的落盘文件复制进 `clipboard/` 目录（内容寻址，与图库 originals/ 同算法）；
/// 文本条目没有文件。文件缺失时 `asset` 为 nil（不中止导出）。
struct PortableLibraryClipboardItem: Codable, Equatable {
    /// 仅在本次导出包内稳定，例如 `clipboard-42`。
    let id: String
    let kind: String
    let contentHash: String
    let text: String?
    let asset: PortableLibraryFile?
    let summary: String?
    let sourceApp: String?
    let pinned: Bool
    let capturedAt: Date
    let lastUsedAt: Date?
    let title: String?
    let isFavorite: Bool
}

/// 剪贴板条目 → 专题收藏集的关联。
struct PortableLibraryClipboardCollectionItem: Codable, Equatable {
    let clipboardID: String
    let addedAt: Date
}

enum PortableLibraryCoding {
    static func makeEncoder(prettyPrinted: Bool = false) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = prettyPrinted ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

enum PortableLibraryExportError: LocalizedError, Equatable {
    case destinationExists(String)
    case invalidRecordID(table: String)
    case invalidContentHash(String)
    case missingOriginal(String)
    case invalidRevision(revisionID: Int64)
    case invalidMoleculeAsset(assetID: Int64)

    var errorDescription: String? {
        switch self {
        case .destinationExists(let path):
            return "导出目标已经存在：\(path)"
        case .invalidRecordID(let table):
            return "\(table) 记录缺少数据库 ID，无法建立包内引用。"
        case .invalidContentHash(let hash):
            return "原图内容哈希无效：\(hash)"
        case .missingOriginal(let path):
            return "图库原图不存在，已停止导出：\(path)"
        case .invalidRevision(let revisionID):
            return "修订 \(revisionID) 的图层 JSON 无法解码，已停止导出以避免丢失标注。"
        case .invalidMoleculeAsset(let assetID):
            return "分子附件 \(assetID) 的 XYZ 来源无法解码，已停止导出以避免丢失坐标。"
        }
    }
}

/// 便携图库包的只读导出器。无 UI、无弹窗、不会修改当前图库。
struct PortableLibraryExporter {
    private let database: any DatabaseWriter
    private let rootDirectory: URL
    private let fileManager: FileManager

    init(
        database: any DatabaseWriter,
        rootDirectory: URL,
        fileManager: FileManager = .default
    ) {
        self.database = database
        self.rootDirectory = rootDirectory
        self.fileManager = fileManager
    }

    @discardableResult
    func export(
        to destination: URL,
        exportedAt: Date = Date(),
        producerVersion: String? = nil
    ) async throws -> PortableLibraryManifest {
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw PortableLibraryExportError.destinationExists(destination.path)
        }

        let snapshot = try await makeSnapshot(
            exportedAt: exportedAt,
            producerVersion: producerVersion
        )
        let parent = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent(
            ".\(destination.lastPathComponent).stage-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
        var shouldCleanStaging = true
        defer {
            if shouldCleanStaging { try? fileManager.removeItem(at: staging) }
        }

        for copy in snapshot.files {
            let target = staging.appendingPathComponent(copy.relativePath)
            try fileManager.createDirectory(
                at: target.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fileManager.copyItem(at: copy.source, to: target)
        }

        let manifestURL = staging.appendingPathComponent("manifest.json")
        let data = try PortableLibraryCoding.makeEncoder(prettyPrinted: true)
            .encode(snapshot.manifest)
        try data.write(to: manifestURL, options: .atomic)
        try fileManager.moveItem(at: staging, to: destination)
        shouldCleanStaging = false
        return snapshot.manifest
    }

    func makeManifest(
        exportedAt: Date = Date(),
        producerVersion: String? = nil
    ) async throws -> PortableLibraryManifest {
        try await makeSnapshot(
            exportedAt: exportedAt,
            producerVersion: producerVersion
        ).manifest
    }

    private struct FileCopy {
        let source: URL
        let relativePath: String
    }

    private struct ExportSnapshot {
        let manifest: PortableLibraryManifest
        let files: [FileCopy]
    }

    private struct DatabaseSnapshot {
        let shots: [Shot]
        let revisions: [Revision]
        let attributes: [ShotAttribute]
        let assets: [ShotAsset]
        let collections: [ShotCollection]
        let collectionItems: [ShotCollectionItem]
        let clipboardItems: [ClipboardHistoryItem]
        let clipboardCollectionItems: [ClipboardCollectionItem]
    }

    private func makeSnapshot(
        exportedAt: Date,
        producerVersion: String?
    ) async throws -> ExportSnapshot {
        let databaseSnapshot = try await database.read { db in
            DatabaseSnapshot(
                shots: try Shot.order(Column("capturedAt").asc, Column("id").asc).fetchAll(db),
                revisions: try Revision
                    .order(Column("shotID").asc, Column("createdAt").asc, Column("id").asc)
                    .fetchAll(db),
                attributes: try ShotAttribute.order(Column("id").asc).fetchAll(db),
                assets: try ShotAsset.order(Column("shotID").asc, Column("id").asc).fetchAll(db),
                collections: try ShotCollection
                    .order(Column("sortOrder").asc, Column("createdAt").asc, Column("id").asc)
                    .fetchAll(db),
                collectionItems: try ShotCollectionItem
                    .order(Column("collectionID").asc, Column("sortOrder").asc,
                           Column("addedAt").asc, Column("shotID").asc)
                    .fetchAll(db),
                clipboardItems: try ClipboardHistoryItem
                    .order(Column("capturedAt").asc, Column("id").asc)
                    .fetchAll(db),
                clipboardCollectionItems: try ClipboardCollectionItem
                    .order(Column("collectionID").asc, Column("clipboardID").asc)
                    .fetchAll(db)
            )
        }

        let revisionsByShot = Dictionary(grouping: databaseSnapshot.revisions, by: \.shotID)
        let attributesByShot = Dictionary(grouping: databaseSnapshot.attributes, by: \.shotID)
        let assetsByShot = Dictionary(grouping: databaseSnapshot.assets, by: \.shotID)
        let itemsByCollection = Dictionary(grouping: databaseSnapshot.collectionItems, by: \.collectionID)
        var files: [FileCopy] = []
        var copiedOriginalHashes = Set<String>()

        let shots = try databaseSnapshot.shots.map { shot -> PortableLibraryShot in
            guard let shotID = shot.id else {
                throw PortableLibraryExportError.invalidRecordID(table: Shot.databaseTableName)
            }
            guard Self.isValidSHA256(shot.sha256) else {
                throw PortableLibraryExportError.invalidContentHash(shot.sha256)
            }
            let shotReference = Self.shotReference(shotID)
            let originalRelativePath = "originals/\(shot.sha256).png"
            let originalURL = rootDirectory.appendingPathComponent(originalRelativePath)
            guard fileManager.fileExists(atPath: originalURL.path) else {
                throw PortableLibraryExportError.missingOriginal(originalURL.path)
            }
            if copiedOriginalHashes.insert(shot.sha256).inserted {
                files.append(FileCopy(source: originalURL, relativePath: originalRelativePath))
            }

            let attributes = attributesByShot[shotID] ?? []
            let favorite = attributes.contains { $0.key == AttributeKey.favorite }
            let tags = attributes.compactMap { attribute in
                attribute.key == AttributeKey.tag ? attribute.text : nil
            }
            let category = attributes.last(where: { $0.key == AttributeKey.category })?.text

            let revisions = try (revisionsByShot[shotID] ?? []).map { revision in
                guard let revisionID = revision.id else {
                    throw PortableLibraryExportError.invalidRecordID(table: Revision.databaseTableName)
                }
                guard let data = revision.layersJSON.data(using: .utf8),
                      let layers = try? JSONDecoder().decode([Layer].self, from: data)
                else {
                    throw PortableLibraryExportError.invalidRevision(revisionID: revisionID)
                }
                return PortableLibraryRevision(
                    id: Self.revisionReference(revisionID),
                    parentID: revision.parentID.map(Self.revisionReference),
                    createdAt: revision.createdAt,
                    note: revision.note,
                    layers: layers
                )
            }

            let assets = try (assetsByShot[shotID] ?? []).map { asset in
                guard let assetID = asset.id else {
                    throw PortableLibraryExportError.invalidRecordID(table: ShotAsset.databaseTableName)
                }
                var relativePath: String?
                var textContent: String?
                var mediaType: String?
                var payload = asset.payload
                var missing = false
                var originalFileName: String?
                if let path = asset.path {
                    let source = URL(fileURLWithPath: path)
                    let filename = Self.safePathComponent(source.lastPathComponent, fallback: "asset")
                    originalFileName = source.lastPathComponent
                    var isDirectory: ObjCBool = false
                    if fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory),
                       !isDirectory.boolValue {
                        let kind = Self.safePathComponent(asset.kind, fallback: "asset")
                        let assetReference = Self.assetReference(assetID)
                        let path = "assets/\(shotReference)/\(assetReference)-\(kind)/\(filename)"
                        relativePath = path
                        files.append(FileCopy(source: source, relativePath: path))
                    } else {
                        missing = true
                    }
                }
                if asset.kind == ShotAssetKind.moleculeXYZ {
                    guard let sourcePayload = asset.payload,
                          let source = try? JSONDecoder().decode(
                              MoleculeSourceAttachment.self,
                              from: sourcePayload
                          )
                    else {
                        throw PortableLibraryExportError.invalidMoleculeAsset(assetID: assetID)
                    }
                    textContent = source.canonicalXYZ
                    mediaType = "chemical/x-xyz"
                    payload = nil
                }
                return PortableLibraryAsset(
                    id: Self.assetReference(assetID),
                    kind: asset.kind,
                    schemaVersion: asset.schemaVersion,
                    relativePath: relativePath,
                    textContent: textContent,
                    mediaType: mediaType,
                    payload: payload,
                    missing: missing,
                    originalFileName: originalFileName,
                    createdAt: asset.createdAt,
                    updatedAt: asset.updatedAt
                )
            }

            let bundleID = shot.appBundleID?.trimmingCharacters(in: .whitespacesAndNewlines)
            return PortableLibraryShot(
                id: shotReference,
                contentHash: shot.sha256,
                original: PortableLibraryFile(
                    relativePath: originalRelativePath,
                    mediaType: "image/png",
                    sha256: shot.sha256
                ),
                capturedAt: shot.capturedAt,
                pixelWidth: shot.pixelWidth,
                pixelHeight: shot.pixelHeight,
                scale: shot.scale,
                customTitle: shot.customTitle,
                source: PortableLibrarySource(
                    appName: shot.appName,
                    appIdentifier: bundleID.flatMap { value in
                        value.isEmpty ? nil : PortableLibraryAppIdentifier(kind: "bundle-id", value: value)
                    },
                    appVersion: shot.appVersion,
                    appBuild: shot.appBuild,
                    windowTitle: shot.windowTitle,
                    url: shot.sourceURL,
                    displayName: shot.displayName,
                    region: PortableLibraryCaptureRegion(
                        x: shot.regionX,
                        y: shot.regionY,
                        width: shot.regionW,
                        height: shot.regionH,
                        coordinateSpace: "macos-global-points-bottom-left"
                    )
                ),
                ocrText: shot.ocrText,
                favorite: favorite,
                tags: tags,
                category: category,
                revisions: revisions,
                assets: assets
            )
        }

        let clipboardItemsByCollection = Dictionary(
            grouping: databaseSnapshot.clipboardCollectionItems,
            by: \.collectionID
        )

        let collections = try databaseSnapshot.collections.map { collection in
            guard let collectionID = collection.id else {
                throw PortableLibraryExportError.invalidRecordID(table: ShotCollection.databaseTableName)
            }
            return PortableLibraryCollection(
                id: Self.collectionReference(collectionID),
                name: collection.name,
                note: collection.note,
                coverShotID: collection.coverShotID.map(Self.shotReference),
                createdAt: collection.createdAt,
                updatedAt: collection.updatedAt,
                sortOrder: collection.sortOrder,
                items: (itemsByCollection[collectionID] ?? []).map { item in
                    PortableLibraryCollectionItem(
                        shotID: Self.shotReference(item.shotID),
                        addedAt: item.addedAt,
                        sortOrder: item.sortOrder
                    )
                },
                clipboardItems: (clipboardItemsByCollection[collectionID] ?? []).map { item in
                    PortableLibraryClipboardCollectionItem(
                        clipboardID: Self.clipboardReference(item.clipboardID),
                        addedAt: item.addedAt
                    )
                }
            )
        }

        // 剪贴板条目：图片/文件条目复制落盘文件进 clipboard/ 目录，文本条目无文件。
        // 文件缺失不中止导出（asset 置 nil），和 shot assets 的 missing 标记一致。
        var copiedClipboardHashes = Set<String>()
        let clipboard = databaseSnapshot.clipboardItems.compactMap { item -> PortableLibraryClipboardItem? in
            guard let itemID = item.id else { return nil }
            var asset: PortableLibraryFile?
            if let assetPath = item.assetPath {
                let relativePath = "clipboard/\(assetPath)"
                let sourceURL = rootDirectory.appendingPathComponent(relativePath)
                if fileManager.fileExists(atPath: sourceURL.path) {
                    if copiedClipboardHashes.insert(item.contentHash).inserted {
                        files.append(FileCopy(source: sourceURL, relativePath: relativePath))
                    }
                    asset = PortableLibraryFile(
                        relativePath: relativePath,
                        mediaType: "application/octet-stream",
                        sha256: item.contentHash
                    )
                }
            }
            return PortableLibraryClipboardItem(
                id: Self.clipboardReference(itemID),
                kind: item.kind.rawValue,
                contentHash: item.contentHash,
                text: item.text,
                asset: asset,
                summary: item.summary,
                sourceApp: item.sourceApp,
                pinned: item.pinned,
                capturedAt: item.capturedAt,
                lastUsedAt: item.lastUsedAt,
                title: item.title,
                isFavorite: item.isFavorite
            )
        }

        return ExportSnapshot(
            manifest: PortableLibraryManifest(
                format: PortableLibraryManifest.formatIdentifier,
                formatVersion: PortableLibraryManifest.currentFormatVersion,
                minimumReaderVersion: 1,
                exportedAt: exportedAt,
                producer: PortableLibraryProducer(
                    name: "Index",
                    version: producerVersion,
                    platform: "macOS"
                ),
                shots: shots,
                collections: collections,
                clipboard: clipboard
            ),
            files: files
        )
    }

    private static func shotReference(_ id: Int64) -> String { "shot-\(id)" }
    private static func revisionReference(_ id: Int64) -> String { "revision-\(id)" }
    private static func assetReference(_ id: Int64) -> String { "asset-\(id)" }
    private static func collectionReference(_ id: Int64) -> String { "collection-\(id)" }
    private static func clipboardReference(_ id: Int64) -> String { "clipboard-\(id)" }

    private static func isValidSHA256(_ value: String) -> Bool {
        value.count == 64
            && value == value.lowercased()
            && value.allSatisfy { $0.isHexDigit }
    }

    private static func safePathComponent(_ value: String, fallback: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let scalars = value.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "_" }
        let result = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return result.isEmpty ? fallback : result
    }
}
