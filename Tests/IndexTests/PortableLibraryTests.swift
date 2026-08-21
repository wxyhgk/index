import CoreGraphics
import Foundation
import GRDB
import XCTest
@testable import IndexApp

@MainActor
final class PortableLibraryTests: XCTestCase {
    private var root: URL!
    private var exportRoot: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("PortableLibraryTests-\(UUID().uuidString)", isDirectory: true)
        root = base.appendingPathComponent("source", isDirectory: true)
        exportRoot = base.appendingPathComponent("exports", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
        }
    }

    func testExportCopiesPortableFilesAndPreservesUserDataRelationships() async throws {
        let (store, database) = try makeStore()
        var metadata = CaptureMetadata()
        metadata.globalRegion = CGRect(x: -120, y: 80, width: 640, height: 360)
        metadata.scale = 2
        metadata.appName = "Microsoft Edge"
        metadata.appBundleID = "com.microsoft.edgemac"
        metadata.appVersion = "130.0"
        metadata.windowTitle = "MR-TADF paper"
        metadata.sourceURL = "https://example.test/paper"
        metadata.displayName = "Type_C"
        let shot = try store.save(image: makeImage(gray: 0.25), metadata: metadata)
        let shotID = try XCTUnwrap(shot.id)

        store.setCustomTitle("MR-TADF 分子", for: shot)
        store.setFavorite(shotIDs: [shotID], isFavorite: true)
        store.addTag(shotID: shotID, "计算化学")
        store.addTag(shotID: shotID, "论文")
        store.writeAttribute(shotID: shotID, key: AttributeKey.category, value: .text("文档"))

        let layer = Layer(
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            kind: .arrow,
            rect: LRect(x: 10, y: 20, w: 30, h: 40),
            color: LColor(r: 1, g: 0, b: 0, a: 1),
            lineWidth: 4,
            text: "",
            fontSize: 28,
            blockScale: nil,
            dim: nil
        )
        XCTAssertNotNil(store.appendRevision(
            shot: shot,
            layers: Layers<ImageSpace>([layer]),
            note: "箭头标记"
        ))

        let molecule = MoleculeSourceAttachment(
            canonicalXYZ: "2\nH2\nH 0 0 0\nH 0 0 0.74\n",
            atomCount: 2,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try store.attachMoleculeSource(molecule, to: shot)
        let recording = root.deletingLastPathComponent().appendingPathComponent("demo recording.mp4")
        try Data("fake-mp4".utf8).write(to: recording)
        try store.attachRecording(at: recording, to: shot)

        let collection = try store.createCollection(name: "MR-TADF", note: "发光分子")
        try store.addToCollection(
            shotIDs: [shotID],
            collectionID: try XCTUnwrap(collection.id)
        )
        // 固定一等字段时间，使 JSON 断言不依赖测试运行时刻。
        try await database.write { db in
            try db.execute(
                sql: "UPDATE shot SET capturedAt = ?, ocrText = ? WHERE id = ?",
                arguments: [Date(timeIntervalSince1970: 1_700_000_100), "delayed fluorescence", shotID]
            )
        }

        let destination = exportRoot.appendingPathComponent("Chemistry.indexlibrary")
        let exportedAt = Date(timeIntervalSince1970: 1_700_001_000)
        _ = try await store.exportPortableLibrary(
            to: destination,
            exportedAt: exportedAt,
            producerVersion: "0.1.8"
        )

        let manifestData = try Data(contentsOf: destination.appendingPathComponent("manifest.json"))
        let manifest = try PortableLibraryCoding.makeDecoder()
            .decode(PortableLibraryManifest.self, from: manifestData)
        XCTAssertEqual(manifest.format, PortableLibraryManifest.formatIdentifier)
        XCTAssertEqual(manifest.formatVersion, 2)
        XCTAssertEqual(manifest.producer, PortableLibraryProducer(
            name: "Index", version: "0.1.8", platform: "macOS"
        ))
        XCTAssertEqual(manifest.shots.count, 1)

        let portableShot = try XCTUnwrap(manifest.shots.first)
        XCTAssertEqual(portableShot.id, "shot-\(shotID)")
        XCTAssertEqual(portableShot.customTitle, "MR-TADF 分子")
        XCTAssertEqual(portableShot.source.appIdentifier, PortableLibraryAppIdentifier(
            kind: "bundle-id", value: "com.microsoft.edgemac"
        ))
        XCTAssertEqual(portableShot.source.region.coordinateSpace, "macos-global-points-bottom-left")
        XCTAssertEqual(portableShot.ocrText, "delayed fluorescence")
        XCTAssertTrue(portableShot.favorite)
        XCTAssertEqual(portableShot.tags, ["计算化学", "论文"])
        XCTAssertEqual(portableShot.category, "文档")
        XCTAssertEqual(portableShot.revisions.count, 2)
        XCTAssertEqual(portableShot.revisions.last?.layers, [layer])

        let moleculeAsset = try XCTUnwrap(portableShot.assets.first {
            $0.kind == ShotAssetKind.moleculeXYZ
        })
        XCTAssertEqual(moleculeAsset.textContent, molecule.canonicalXYZ)
        XCTAssertEqual(moleculeAsset.mediaType, "chemical/x-xyz")
        XCTAssertNil(moleculeAsset.payload)
        XCTAssertNil(moleculeAsset.relativePath)
        XCTAssertFalse(moleculeAsset.missing)

        let recordingAsset = try XCTUnwrap(portableShot.assets.first {
            $0.kind == ShotAssetKind.recording
        })
        let relativeRecordingPath = try XCTUnwrap(recordingAsset.relativePath)
        XCTAssertEqual(recordingAsset.originalFileName, "demo recording.mp4")
        XCTAssertFalse(relativeRecordingPath.hasPrefix("/"))
        XCTAssertFalse(relativeRecordingPath.contains(".."))
        XCTAssertEqual(
            try Data(contentsOf: destination.appendingPathComponent(relativeRecordingPath)),
            Data("fake-mp4".utf8)
        )
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent(portableShot.original.relativePath).path
        ))

        let portableCollection = try XCTUnwrap(manifest.collections.first)
        XCTAssertEqual(portableCollection.name, "MR-TADF")
        XCTAssertEqual(portableCollection.items.map(\.shotID), [portableShot.id])

        let json = try XCTUnwrap(String(data: manifestData, encoding: .utf8))
        XCTAssertFalse(json.contains(recording.deletingLastPathComponent().path))
        XCTAssertEqual(
            try PortableLibraryCoding.makeEncoder(prettyPrinted: true).encode(manifest),
            manifestData,
            "Windows fixture should be deterministic after decode/encode"
        )
    }

    func testMissingExternalAssetKeepsIdentityWithoutLeakingAbsolutePath() async throws {
        let (store, database) = try makeStore()
        let shot = try store.save(image: makeImage(gray: 0.5), metadata: CaptureMetadata())
        let missing = root.deletingLastPathComponent()
            .appendingPathComponent("private/user/path/missing.mp4")
        try store.attachRecording(at: missing, to: shot)

        let manifest = try await PortableLibraryExporter(
            database: database,
            rootDirectory: root
        ).makeManifest(exportedAt: Date(timeIntervalSince1970: 1))

        let asset = try XCTUnwrap(manifest.shots.first?.assets.first)
        XCTAssertEqual(asset.kind, ShotAssetKind.recording)
        XCTAssertTrue(asset.missing)
        XCTAssertNil(asset.relativePath)
        XCTAssertEqual(asset.originalFileName, "missing.mp4")
        let json = String(
            data: try PortableLibraryCoding.makeEncoder().encode(manifest),
            encoding: .utf8
        ) ?? ""
        XCTAssertFalse(json.contains(missing.deletingLastPathComponent().path))
    }

    func testMissingOriginalFailsWithoutLeavingPartialPackage() async throws {
        let (store, _) = try makeStore()
        let shot = try store.save(image: makeImage(gray: 0.75), metadata: CaptureMetadata())
        try FileManager.default.removeItem(at: store.originalURL(for: shot))
        let destination = exportRoot.appendingPathComponent("Broken.indexlibrary")

        do {
            _ = try await store.exportPortableLibrary(to: destination)
            XCTFail("Expected missing original failure")
        } catch let error as PortableLibraryExportError {
            guard case .missingOriginal = error else {
                return XCTFail("Unexpected export error: \(error)")
            }
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: exportRoot.path)) ?? []
        XCTAssertTrue(leftovers.isEmpty)
    }

    func testExistingDestinationIsNeverOverwritten() async throws {
        let (store, _) = try makeStore()
        _ = try store.save(image: makeImage(gray: 0.9), metadata: CaptureMetadata())
        let destination = exportRoot.appendingPathComponent("Existing.indexlibrary")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let sentinel = destination.appendingPathComponent("keep-me.txt")
        try Data("user-data".utf8).write(to: sentinel)

        do {
            _ = try await store.exportPortableLibrary(to: destination)
            XCTFail("Expected destinationExists")
        } catch let error as PortableLibraryExportError {
            XCTAssertEqual(error, .destinationExists(destination.path))
        }

        XCTAssertEqual(try Data(contentsOf: sentinel), Data("user-data".utf8))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("manifest.json").path
        ))
    }

    func testInvalidMoleculePayloadFailsInsteadOfDroppingXYZSource() async throws {
        let (store, database) = try makeStore()
        let shot = try store.save(image: makeImage(gray: 0.8), metadata: CaptureMetadata())
        try store.attachMoleculeSource(
            MoleculeSourceAttachment(canonicalXYZ: "1\nH\nH 0 0 0\n", atomCount: 1),
            to: shot
        )
        let shotID = try XCTUnwrap(shot.id)
        let assetID = try await database.write { db in
            try db.execute(
                sql: "UPDATE shotAsset SET payload = ? WHERE shotID = ? AND kind = ?",
                arguments: [Data("not-json".utf8), shotID, ShotAssetKind.moleculeXYZ]
            )
            return try Int64.fetchOne(
                db,
                sql: "SELECT id FROM shotAsset WHERE shotID = ? AND kind = ?",
                arguments: [shotID, ShotAssetKind.moleculeXYZ]
            )
        }

        do {
            _ = try await PortableLibraryExporter(
                database: database,
                rootDirectory: root
            ).makeManifest()
            XCTFail("Expected invalid molecule payload failure")
        } catch let error as PortableLibraryExportError {
            XCTAssertEqual(error, .invalidMoleculeAsset(assetID: try XCTUnwrap(assetID)))
        }
    }

    func testLayerSchemaKindListTracksSwiftEnum() throws {
        let contractRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Contracts")
        let schemaData = try Data(contentsOf: contractRoot.appendingPathComponent("layers-v1.schema.json"))
        let schema = try XCTUnwrap(
            JSONSerialization.jsonObject(with: schemaData) as? [String: Any]
        )
        let definitions = try XCTUnwrap(schema["$defs"] as? [String: Any])
        let layer = try XCTUnwrap(definitions["layer"] as? [String: Any])
        let properties = try XCTUnwrap(layer["properties"] as? [String: Any])
        let kind = try XCTUnwrap(properties["kind"] as? [String: Any])
        let schemaKinds = Set(try XCTUnwrap(kind["enum"] as? [String]))

        XCTAssertEqual(schemaKinds, Set(Layer.Kind.allCases.map(\.rawValue)))
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(contentsOf:
            contractRoot.appendingPathComponent("portable-library-v1.schema.json")
        )))
    }

    private func makeStore() throws -> (ShotStore, DatabaseQueue) {
        let database = try DatabaseQueue()
        try AppDatabase.migrator.migrate(database)
        return (ShotStore(rootDirectory: root, database: database), database)
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
}
