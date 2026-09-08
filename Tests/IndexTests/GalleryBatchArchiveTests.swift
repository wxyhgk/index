import CoreGraphics
import Foundation
import XCTest
@testable import IndexApp

@MainActor
final class GalleryBatchArchiveTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GalleryBatchArchiveTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        if let token = GalleryWindowController.shared.batchActivity.state?.token {
            GalleryWindowController.shared.batchActivity.finish(token: token)
        }
    }

    override func tearDownWithError() throws {
        if let token = GalleryWindowController.shared.batchActivity.state?.token {
            GalleryWindowController.shared.batchActivity.finish(token: token)
        }
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    func testArchiveWriterProducesValidZIPAndAllocatesNamesCaseInsensitively() throws {
        let destination = temporaryDirectory.appendingPathComponent("selection.zip")
        let writer = try BatchArchiveExporter.Writer(
            destination: destination,
            allowsReplacingExisting: false
        )

        XCTAssertEqual(try writer.appendPNG(Data([1, 2, 3]), preferredName: "shot.png"), "shot.png")
        XCTAssertEqual(try writer.appendPNG(Data([4, 5]), preferredName: "SHOT.PNG"), "SHOT-2.PNG")
        XCTAssertEqual(try writer.finish(), destination)

        XCTAssertEqual(try archiveListing(destination), ["shot.png", "SHOT-2.PNG"])
        XCTAssertEqual(try archiveTestOutput(destination), "No errors detected in compressed data of \(destination.path).")
    }

    func testCancelledWriterLeavesNoDestinationOrPartialFile() throws {
        let destination = temporaryDirectory.appendingPathComponent("cancelled.zip")
        let writer = try BatchArchiveExporter.Writer(destination: destination)
        try writer.appendPNG(Data([1, 2, 3]), preferredName: "one.png")
        writer.cancel()

        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        let siblings = try FileManager.default.contentsOfDirectory(
            at: temporaryDirectory,
            includingPropertiesForKeys: nil
        )
        XCTAssertFalse(siblings.contains { $0.pathExtension == "partial" })
    }

    func testWriterAtomicallyReplacesExplicitlyConfirmedDestination() throws {
        let destination = temporaryDirectory.appendingPathComponent("existing.zip")
        try Data("old".utf8).write(to: destination)
        let writer = try BatchArchiveExporter.Writer(
            destination: destination,
            allowsReplacingExisting: true
        )
        try writer.appendPNG(Data([9, 8, 7]), preferredName: "new.png")

        try writer.finish()

        XCTAssertEqual(try archiveListing(destination), ["new.png"])
    }

    func testBatchZIPDeduplicatesIDsAndExportsRenderedPNGEntries() async throws {
        let store = FakeShotStore(rootDirectory: temporaryDirectory.appendingPathComponent("store"))
        let first = try store.save(image: makeImage(gray: 0.2), metadata: CaptureMetadata())
        let second = try store.save(image: makeImage(gray: 0.8), metadata: CaptureMetadata())
        let destination = temporaryDirectory.appendingPathComponent("batch.zip")

        let count = await GalleryBatch.exportZIP(
            ids: [try XCTUnwrap(first.id), try XCTUnwrap(second.id), try XCTUnwrap(first.id), 999_999],
            reader: store,
            destination: destination
        )

        XCTAssertEqual(count, 2)
        XCTAssertEqual(try archiveListing(destination).count, 2)
        XCTAssertFalse(GalleryWindowController.shared.batchActivity.isBusy)
    }

    func testBatchTagAddAndRemoveTrimsNameAndDeduplicatesIDs() throws {
        let store = FakeShotStore(rootDirectory: temporaryDirectory.appendingPathComponent("tags"))
        let first = try store.save(image: makeImage(gray: 0.2), metadata: CaptureMetadata())
        let second = try store.save(image: makeImage(gray: 0.8), metadata: CaptureMetadata())
        let ids = [try XCTUnwrap(first.id), try XCTUnwrap(second.id), try XCTUnwrap(first.id)]

        GalleryBatch.setTag(ids: ids, name: "  项目 A  ", isPresent: true, writer: store)
        XCTAssertEqual(store.tags(shotID: ids[0]), ["项目 A"])
        XCTAssertEqual(store.tags(shotID: ids[1]), ["项目 A"])

        GalleryBatch.setTag(ids: ids, name: "项目 A", isPresent: false, writer: store)
        XCTAssertEqual(store.tags(shotID: ids[0]), [])
        XCTAssertEqual(store.tags(shotID: ids[1]), [])
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
        context.setFillColor(CGColor(gray: gray, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        return try XCTUnwrap(context.makeImage())
    }

    private func archiveListing(_ url: URL) throws -> [String] {
        try run("/usr/bin/unzip", arguments: ["-Z1", url.path])
            .split(separator: "\n")
            .map(String.init)
    }

    private func archiveTestOutput(_ url: URL) throws -> String {
        try run("/usr/bin/unzip", arguments: ["-t", url.path])
            .split(separator: "\n")
            .last
            .map(String.init) ?? ""
    }

    private func run(_ executable: String, arguments: [String]) throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(
            data: pipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, output)
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
