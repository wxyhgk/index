import Foundation
import GRDB
import CryptoKit

/// 从便携图库包恢复数据到本地数据库。
///
/// 导入是幂等的：按内容哈希去重，重复导入不产生重复数据。
/// 失败时整个事务回滚，本地数据不受影响。
struct PortableLibraryImporter {

    struct Report: Equatable {
        var shotsImported = 0
        var shotsSkipped = 0
        var collectionsImported = 0
        var collectionsMerged = 0
        var clipboardImported = 0
        var clipboardSkipped = 0

        var summary: String {
            var parts: [String] = []
            if shotsImported > 0 { parts.append("\(shotsImported) 张截图") }
            if shotsSkipped > 0 { parts.append("\(shotsSkipped) 张已存在") }
            if collectionsImported > 0 { parts.append("\(collectionsImported) 个专题集") }
            if collectionsMerged > 0 { parts.append("\(collectionsMerged) 个已合并") }
            if clipboardImported > 0 { parts.append("\(clipboardImported) 条剪贴板") }
            if clipboardSkipped > 0 { parts.append("\(clipboardSkipped) 条已存在") }
            return parts.isEmpty ? "没有可导入的数据" : parts.joined(separator: "、")
        }
    }

    enum ImportError: LocalizedError, Equatable {
        case notAPortableLibrary(String)
        case unsupportedFormatVersion(Int)
        case missingManifest

        var errorDescription: String? {
            switch self {
            case .notAPortableLibrary(let path):
                return "不是有效的便携图库包：\(path)"
            case .unsupportedFormatVersion(let version):
                return "便携图库包格式版本 \(version) 不受支持"
            case .missingManifest:
                return "便携图库包缺少 manifest.json"
            }
        }
    }

    private let writer: any DatabaseWriter
    private let rootDirectory: URL
    private let fileManager: FileManager

    init(
        writer: any DatabaseWriter,
        rootDirectory: URL,
        fileManager: FileManager = .default
    ) {
        self.writer = writer
        self.rootDirectory = rootDirectory
        self.fileManager = fileManager
    }

    /// 从便携图库包目录导入。单事务，失败回滚。
    func importLibrary(at directory: URL) async throws -> Report {
        let manifestURL = directory.appendingPathComponent("manifest.json")
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            throw ImportError.missingManifest
        }
        let manifestData = try Data(contentsOf: manifestURL)

        // 先轻量验证 format 标识，避免非便携图库包因缺少字段而报解码错误。
        struct Header: Decodable {
            let format: String
            let formatVersion: Int
        }
        let header = try PortableLibraryCoding.makeDecoder()
            .decode(Header.self, from: manifestData)
        guard header.format == PortableLibraryManifest.formatIdentifier else {
            throw ImportError.notAPortableLibrary(directory.path)
        }
        guard header.formatVersion <= PortableLibraryManifest.currentFormatVersion else {
            throw ImportError.unsupportedFormatVersion(header.formatVersion)
        }

        let manifest = try PortableLibraryCoding.makeDecoder()
            .decode(PortableLibraryManifest.self, from: manifestData)

        let originalsDir = rootDirectory.appendingPathComponent("originals", isDirectory: true)
        let thumbnailsDir = rootDirectory.appendingPathComponent("thumbnails", isDirectory: true)
        let clipboardDir = rootDirectory.appendingPathComponent("clipboard", isDirectory: true)
        for dir in [originalsDir, thumbnailsDir, clipboardDir] {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        return try await writer.write { db in
            var report = Report()

            // ── 1. 导入 shots ──
            // 按 sha256 去重。已存在的记录映射关系，不覆盖。
            let existingShots = try Shot.fetchAll(db)
            var shaToShotID: [String: Int64] = [:]
            for shot in existingShots {
                if let id = shot.id { shaToShotID[shot.sha256] = id }
            }

            // manifestShotID → localShotID 映射
            var shotIDMap: [String: Int64] = [:]

            for portableShot in manifest.shots {
                if let existingID = shaToShotID[portableShot.contentHash] {
                    shotIDMap[portableShot.id] = existingID
                    report.shotsSkipped += 1
                    continue
                }

                // 复制原图
                let originalFile = directory.appendingPathComponent(portableShot.original.relativePath)
                let ext = (portableShot.original.relativePath as NSString).pathExtension
                let targetOriginal = originalsDir.appendingPathComponent(
                    "\(portableShot.contentHash).\(ext)"
                )
                if fileManager.fileExists(atPath: originalFile.path) {
                    if !fileManager.fileExists(atPath: targetOriginal.path) {
                        try fileManager.copyItem(at: originalFile, to: targetOriginal)
                    }
                }

                // 生成缩略图
                let thumbTarget = thumbnailsDir.appendingPathComponent(
                    "\(portableShot.contentHash).jpg"
                )
                if !fileManager.fileExists(atPath: thumbTarget.path) {
                    if let image = ImageCodec.load(from: targetOriginal),
                       let thumb = ImageCodec.resized(image, maxDimension: 640),
                       let jpg = ImageCodec.jpegData(from: thumb) {
                        try? jpg.write(to: thumbTarget, options: .atomic)
                    }
                }

                // 插入 shot 行
                var shot = Shot(
                    id: nil,
                    sha256: portableShot.contentHash,
                    capturedAt: portableShot.capturedAt,
                    pixelWidth: portableShot.pixelWidth,
                    pixelHeight: portableShot.pixelHeight,
                    scale: portableShot.scale,
                    appName: portableShot.source.appName,
                    appBundleID: portableShot.source.appIdentifier?.value,
                    appVersion: portableShot.source.appVersion,
                    appBuild: portableShot.source.appBuild,
                    windowTitle: portableShot.source.windowTitle,
                    customTitle: portableShot.customTitle,
                    sourceURL: portableShot.source.url,
                    displayID: nil,
                    displayName: portableShot.source.displayName,
                    regionX: portableShot.source.region.x,
                    regionY: portableShot.source.region.y,
                    regionW: portableShot.source.region.width,
                    regionH: portableShot.source.region.height,
                    ocrText: portableShot.ocrText,
                    originalExtension: ext
                )
                try shot.insert(db)
                guard let localShotID = shot.id else { continue }
                shotIDMap[portableShot.id] = localShotID
                report.shotsImported += 1

                // 插入初始 revision（空图层）
                var initialRevision = Revision(
                    id: nil,
                    shotID: localShotID,
                    parentID: nil,
                    createdAt: portableShot.capturedAt,
                    note: "原始",
                    layersJSON: "[]"
                )
                try initialRevision.insert(db)

                // 导入 attributes（tags / favorite / category）
                if portableShot.favorite {
                    try insertAttribute(db, shotID: localShotID, key: AttributeKey.favorite)
                }
                for tag in portableShot.tags {
                    try insertAttribute(db, shotID: localShotID, key: AttributeKey.tag, text: tag)
                }
                if let category = portableShot.category {
                    try insertAttribute(db, shotID: localShotID, key: AttributeKey.category, text: category)
                }

                // 导入 revisions（标注图层，两遍法）
                try importRevisions(db, portableShot: portableShot, localShotID: localShotID)

                // 导入 assets（附件）
                try importAssets(db, portableShot: portableShot, localShotID: localShotID, packageDir: directory)
            }

            // ── 2. 导入 collections ──
            // 按 name NOCASE 去重。已存在的合并成员。
            let existingCollections = try ShotCollection.fetchAll(db)
            var nameToCollectionID: [String: Int64] = [:]
            for collection in existingCollections {
                if let id = collection.id {
                    nameToCollectionID[collection.name.lowercased()] = id
                }
            }

            // manifestCollectionID → localCollectionID
            var collectionIDMap: [String: Int64] = [:]

            for portableCollection in manifest.collections {
                let nameKey = portableCollection.name.lowercased()
                let localCollectionID: Int64
                if let existingID = nameToCollectionID[nameKey] {
                    localCollectionID = existingID
                    report.collectionsMerged += 1
                } else {
                    var collection = ShotCollection(
                        id: nil,
                        name: portableCollection.name,
                        note: portableCollection.note,
                        coverShotID: nil,
                        createdAt: portableCollection.createdAt,
                        updatedAt: portableCollection.updatedAt,
                        sortOrder: portableCollection.sortOrder
                    )
                    try collection.insert(db)
                    localCollectionID = collection.id ?? 0
                    nameToCollectionID[nameKey] = localCollectionID
                    report.collectionsImported += 1
                }
                collectionIDMap[portableCollection.id] = localCollectionID

                // 导入 shot 成员
                for item in portableCollection.items {
                    guard let localShotID = shotIDMap[item.shotID] else { continue }
                    try db.execute(sql: """
                        INSERT OR IGNORE INTO shotCollectionItem
                            (collectionID, shotID, addedAt, sortOrder)
                        VALUES (?, ?, ?, ?)
                        """, arguments: [
                        localCollectionID, localShotID, item.addedAt, item.sortOrder
                    ])
                }

                // 导入 clipboard 成员（需要 clipboardIDMap，先收集）
                // 延迟到 clipboard 导入后处理
            }

            // ── 3. 导入 clipboard ──
            let existingClipboard = try ClipboardHistoryItem.fetchAll(db)
            var hashToClipboardID: [String: Int64] = [:]
            for item in existingClipboard {
                if let id = item.id { hashToClipboardID[item.contentHash] = id }
            }

            var clipboardIDMap: [String: Int64] = [:]

            for portableItem in manifest.clipboard {
                if let existingID = hashToClipboardID[portableItem.contentHash] {
                    clipboardIDMap[portableItem.id] = existingID
                    report.clipboardSkipped += 1
                    continue
                }

                // 复制图片/文件资产
                var assetPath: String?
                if let asset = portableItem.asset {
                    let sourceFile = directory.appendingPathComponent(asset.relativePath)
                    let fileName = (asset.relativePath as NSString).lastPathComponent
                    let targetFile = clipboardDir.appendingPathComponent(fileName)
                    if fileManager.fileExists(atPath: sourceFile.path) {
                        if !fileManager.fileExists(atPath: targetFile.path) {
                            try fileManager.copyItem(at: sourceFile, to: targetFile)
                        }
                        assetPath = fileName
                    }
                }

                var item = ClipboardHistoryItem(
                    id: nil,
                    kind: ClipboardHistoryKind(rawValue: portableItem.kind) ?? .text,
                    contentHash: portableItem.contentHash,
                    text: portableItem.text,
                    assetPath: assetPath,
                    summary: portableItem.summary,
                    sourceApp: portableItem.sourceApp,
                    pinned: portableItem.pinned,
                    capturedAt: portableItem.capturedAt,
                    lastUsedAt: portableItem.lastUsedAt,
                    title: portableItem.title,
                    isFavorite: portableItem.isFavorite
                )
                try item.insert(db)
                guard let localClipboardID = item.id else { continue }
                clipboardIDMap[portableItem.id] = localClipboardID
                report.clipboardImported += 1
            }

            // ── 4. 导入 clipboard collection items ──
            for portableCollection in manifest.collections {
                guard let localCollectionID = collectionIDMap[portableCollection.id] else { continue }
                for item in portableCollection.clipboardItems {
                    guard let localClipboardID = clipboardIDMap[item.clipboardID] else { continue }
                    try db.execute(sql: """
                        INSERT OR IGNORE INTO clipboardCollectionItem
                            (collectionID, clipboardID, addedAt)
                        VALUES (?, ?, ?)
                        """, arguments: [localCollectionID, localClipboardID, item.addedAt])
                }
            }

            return report
        }
    }

    // MARK: - 辅助

    private func insertAttribute(
        _ db: Database,
        shotID: Int64,
        key: String,
        text: String? = nil
    ) throws {
        try db.execute(sql: """
            INSERT OR IGNORE INTO shotAttribute (shotID, key, text, createdAt)
            VALUES (?, ?, ?, ?)
            """, arguments: [shotID, key, text, Date()])
    }

    private func importRevisions(
        _ db: Database,
        portableShot: PortableLibraryShot,
        localShotID: Int64
    ) throws {
        // 跳过初始 revision（layers 为空），它已经在 shot 插入时创建了。
        // 只导入有实际图层的 revision。
        let nonInitialRevisions = portableShot.revisions.filter { !$0.layers.isEmpty }
        guard !nonInitialRevisions.isEmpty else { return }

        // 两遍法：第一遍插入（parentID = nil），建立映射；第二遍更新 parentID。
        var revisionIDMap: [String: Int64] = [:]
        for portableRevision in nonInitialRevisions {
            let layersJSON = (try? JSONEncoder().encode(portableRevision.layers))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
            var revision = Revision(
                id: nil,
                shotID: localShotID,
                parentID: nil,
                createdAt: portableRevision.createdAt,
                note: portableRevision.note,
                layersJSON: layersJSON
            )
            try revision.insert(db)
            if let localID = revision.id {
                revisionIDMap[portableRevision.id] = localID
            }
        }

        // 第二遍：更新 parentID
        for portableRevision in nonInitialRevisions {
            guard let localID = revisionIDMap[portableRevision.id],
                  let parentRef = portableRevision.parentID,
                  let localParentID = revisionIDMap[parentRef]
            else { continue }
            try db.execute(
                sql: "UPDATE revision SET parentID = ? WHERE id = ?",
                arguments: [localParentID, localID]
            )
        }
    }

    private func importAssets(
        _ db: Database,
        portableShot: PortableLibraryShot,
        localShotID: Int64,
        packageDir: URL
    ) throws {
        for portableAsset in portableShot.assets {
            // 按 shotID + kind 去重
            let existing = try ShotAsset
                .filter(Column("shotID") == localShotID && Column("kind") == portableAsset.kind)
                .fetchOne(db)
            if existing != nil { continue }

            var asset = ShotAsset(
                id: nil,
                shotID: localShotID,
                kind: portableAsset.kind,
                path: nil,
                payload: portableAsset.payload,
                schemaVersion: portableAsset.schemaVersion,
                createdAt: portableAsset.createdAt,
                updatedAt: portableAsset.updatedAt
            )

            // 文件附件：复制进本地 assets/ 目录
            if let relativePath = portableAsset.relativePath {
                let sourceFile = packageDir.appendingPathComponent(relativePath)
                if fileManager.fileExists(atPath: sourceFile.path) {
                    let targetFile = rootDirectory.appendingPathComponent(relativePath)
                    if !fileManager.fileExists(atPath: targetFile.path) {
                        try fileManager.createDirectory(
                            at: targetFile.deletingLastPathComponent(),
                            withIntermediateDirectories: true
                        )
                        try fileManager.copyItem(at: sourceFile, to: targetFile)
                    }
                    asset.path = targetFile.path
                }
            }

            // 分子 XYZ：从 textContent 重建 payload
            if portableAsset.kind == ShotAssetKind.moleculeXYZ,
               let text = portableAsset.textContent,
               asset.payload == nil {
                let source = MoleculeSourceAttachment(
                    canonicalXYZ: text,
                    atomCount: text.split(separator: "\n").first.flatMap { Int($0) } ?? 0,
                    createdAt: portableAsset.createdAt
                )
                asset.payload = try? JSONEncoder().encode(source)
            }

            try asset.insert(db)
        }
    }
}
