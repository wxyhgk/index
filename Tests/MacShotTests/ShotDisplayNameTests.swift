import XCTest
@testable import MacShot

final class ShotDisplayNameTests: XCTestCase {

    func testPrimaryDisplayNamePrefersSourceApp() {
        var shot = makeShot()
        shot.appName = "预览"
        shot.windowTitle = "diagram.png"

        XCTAssertEqual(shot.primaryDisplayName, "预览")
    }

    func testPrimaryDisplayNameFallsBackToImportedFileName() {
        var shot = makeShot()
        shot.windowTitle = "MR-TADF.png"

        XCTAssertEqual(shot.primaryDisplayName, "MR-TADF.png")
    }

    func testPrimaryDisplayNameDoesNotCallMissingMetadataAnApp() {
        XCTAssertEqual(makeShot().primaryDisplayName, "未知来源")
    }

    private func makeShot() -> Shot {
        Shot(
            id: 1,
            sha256: "hash",
            capturedAt: Date(timeIntervalSince1970: 0),
            pixelWidth: 1,
            pixelHeight: 1,
            scale: 1,
            appName: nil,
            appBundleID: nil,
            appVersion: nil,
            appBuild: nil,
            windowTitle: nil,
            sourceURL: nil,
            displayID: nil,
            displayName: nil,
            regionX: 0,
            regionY: 0,
            regionW: 1,
            regionH: 1,
            ocrText: nil
        )
    }
}
