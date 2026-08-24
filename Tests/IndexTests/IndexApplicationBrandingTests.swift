import AppKit
import XCTest
@testable import IndexApp

final class IndexApplicationBrandingTests: XCTestCase {

    @MainActor
    func testApplicationIconLoadsFromSwiftPMResources() throws {
        let image = try XCTUnwrap(IndexApplicationBranding.applicationIcon())
        XCTAssertEqual(image.size, NSSize(width: 1024, height: 1024))
        XCTAssertFalse(image.isTemplate)
    }

    @MainActor
    func testMenuBarIconIsAnEighteenPointTemplate() throws {
        let image = try XCTUnwrap(IndexApplicationBranding.menuBarIcon())
        XCTAssertEqual(image.size, NSSize(width: 18, height: 18))
        XCTAssertTrue(image.isTemplate)
    }

    @MainActor
    func testDockTileUsesBrandImageInsteadOfGenericExecutableIcon() throws {
        let image = try XCTUnwrap(IndexApplicationBranding.applicationIcon())
        let tileView = IndexApplicationBranding.dockTileContentView(image: image)

        XCTAssertTrue(tileView.image === image)
        XCTAssertEqual(tileView.frame.size, NSSize(width: 128, height: 128))
        XCTAssertEqual(tileView.imageScaling, .scaleProportionallyUpOrDown)
    }
}
