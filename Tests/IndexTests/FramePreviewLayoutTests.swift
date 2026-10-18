import XCTest
@testable import IndexApp

final class FramePreviewLayoutTests: XCTestCase {

    func testPanelAvoidsSelectionAndToolbar() {
        let bounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let selection = CGRect(x: 100, y: 100, width: 400, height: 300)
        let toolbar = CGRect(x: 120, y: 40, width: 500, height: 44)

        let panel = FramePreviewLayout.panelRect(
            imageSize: CGSize(width: 800, height: 400),
            bounds: bounds,
            selection: selection,
            obstacles: [toolbar]
        )

        XCTAssertTrue(bounds.contains(panel))
        XCTAssertFalse(panel.intersects(selection.insetBy(dx: -4, dy: -4)))
        XCTAssertFalse(panel.intersects(toolbar.insetBy(dx: -6, dy: -6)))
        XCTAssertGreaterThan(panel.width, 0)
        XCTAssertGreaterThan(panel.height, 0)
    }

    func testPanelClampsToTinyBounds() {
        let bounds = CGRect(x: 0, y: 0, width: 320, height: 240)
        let selection = CGRect(x: 10, y: 10, width: 300, height: 220)

        let panel = FramePreviewLayout.panelRect(
            imageSize: CGSize(width: 1600, height: 1000),
            bounds: bounds,
            selection: selection,
            obstacles: []
        )

        XCTAssertGreaterThanOrEqual(panel.minX, bounds.minX + FramePreviewLayout.margin)
        XCTAssertGreaterThanOrEqual(panel.minY, bounds.minY + FramePreviewLayout.margin)
        XCTAssertLessThanOrEqual(panel.maxX, bounds.maxX - FramePreviewLayout.margin + 0.001)
        XCTAssertLessThanOrEqual(panel.maxY, bounds.maxY - FramePreviewLayout.margin + 0.001)
    }

    func testImageRectKeepsAspectRatio() {
        let panel = CGRect(x: 0, y: 0, width: 300, height: 200)
        let image = FramePreviewLayout.imageRect(
            in: panel,
            imageSize: CGSize(width: 1600, height: 900)
        )

        XCTAssertEqual(image.width / image.height, 1600.0 / 900.0, accuracy: 0.001)
        XCTAssertTrue(panel.contains(image))
    }
}
