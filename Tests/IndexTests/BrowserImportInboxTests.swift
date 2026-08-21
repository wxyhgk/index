import Foundation
import XCTest
@testable import IndexApp

final class BrowserImportInboxTests: XCTestCase {

    func testResolvesUUIDScopedImageAndMetadata() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let directory = root.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("image".utf8).write(to: directory.appendingPathComponent("molecule.png"))
        try writeMetadata(
            .init(
                schemaVersion: 1,
                imageFile: "molecule.png",
                fileName: "molecule.png",
                mimeType: "image/png",
                pageURL: "https://example.test/paper",
                pageTitle: "Paper",
                imageURL: "https://example.test/molecule.png"
            ),
            to: directory
        )

        let item = try BrowserImportInbox.item(id: id.uuidString, rootDirectory: root)

        XCTAssertEqual(item.id, id)
        XCTAssertEqual(item.imageURL.lastPathComponent, "molecule.png")
        XCTAssertEqual(item.metadata.pageTitle, "Paper")
    }

    func testRejectsArbitraryPathsAndDoesNotDeleteOutsideRoot() throws {
        let root = temporaryDirectory()
        let outside = temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let id = UUID()
        let directory = root.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("secret".utf8).write(to: outside.appendingPathComponent("secret.png"))
        try writeMetadata(
            .init(
                schemaVersion: 1,
                imageFile: "../secret.png",
                fileName: "secret.png",
                mimeType: "image/png",
                pageURL: nil,
                pageTitle: nil,
                imageURL: nil
            ),
            to: directory
        )

        XCTAssertThrowsError(try BrowserImportInbox.item(id: id.uuidString, rootDirectory: root)) {
            XCTAssertEqual($0 as? BrowserImportInbox.InboxError, .unsafeImagePath)
        }
        BrowserImportInbox.remove(id: id, rootDirectory: root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.appendingPathComponent("secret.png").path))
    }

    func testRejectsNonUUIDIdentifier() {
        XCTAssertThrowsError(try BrowserImportInbox.item(id: "../../Documents", rootDirectory: temporaryDirectory())) {
            XCTAssertEqual($0 as? BrowserImportInbox.InboxError, .invalidID)
        }
    }

    private func writeMetadata(_ metadata: BrowserImportInbox.Metadata, to directory: URL) throws {
        try JSONEncoder().encode(metadata).write(to: directory.appendingPathComponent("metadata.json"))
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("BrowserImportInboxTests-\(UUID().uuidString)", isDirectory: true)
    }
}
