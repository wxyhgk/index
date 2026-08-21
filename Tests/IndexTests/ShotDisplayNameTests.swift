import XCTest
@testable import IndexApp

final class ShotDisplayNameTests: XCTestCase {

    func testPrimaryDisplayNamePrefersWindowTitleOverSourceApp() {
        var shot = makeShot()
        shot.appName = "预览"
        shot.windowTitle = "diagram.png"

        XCTAssertEqual(shot.primaryDisplayName, "diagram.png")
    }

    func testPrimaryDisplayNamePrefersCustomTitle() {
        var shot = makeShot()
        shot.appName = "预览"
        shot.windowTitle = "diagram.png"
        shot.customTitle = "MR-TADF 分子轨道"

        XCTAssertEqual(shot.primaryDisplayName, "MR-TADF 分子轨道")
    }

    func testPrimaryDisplayNameFallsBackToImportedFileName() {
        var shot = makeShot()
        shot.windowTitle = "MR-TADF.png"

        XCTAssertEqual(shot.primaryDisplayName, "MR-TADF.png")
    }

    func testPrimaryDisplayNameDoesNotCallMissingMetadataAnApp() {
        XCTAssertEqual(makeShot().primaryDisplayName, "未知来源")
    }

    func testCustomTitleNormalizationTrimsClearsAndLimitsLength() {
        XCTAssertEqual(Shot.normalizedCustomTitle("  分子结构  "), "分子结构")
        XCTAssertNil(Shot.normalizedCustomTitle("  \n  "))
        XCTAssertEqual(
            Shot.normalizedCustomTitle(String(repeating: "A", count: 100))?.count,
            Shot.customTitleMaxLength
        )
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
