import XCTest
@testable import IndexApp

final class PrivacyMaskGeometryTests: XCTestCase {

    func testMapsPixelRegionToCanvasPoints() {
        let rects = PrivacyMaskGeometry.canvasRects(
            regions: [
                SensitiveRegion(
                    rect: CGRect(x: 10, y: 20, width: 40, height: 20),
                    kind: "邮箱",
                    preview: "ab***@x.com"
                )
            ],
            activeRegion: CGRect(x: 20, y: 20, width: 60, height: 60),
            displayFrame: CGRect(x: 0, y: 0, width: 100, height: 100),
            scale: 2
        )
        XCTAssertEqual(rects.count, 1)
        XCTAssertEqual(rects[0].origin.x, 25, accuracy: 0.001)
        XCTAssertEqual(rects[0].origin.y, 30, accuracy: 0.001)
        XCTAssertEqual(rects[0].width, 20, accuracy: 0.001)
        XCTAssertEqual(rects[0].height, 10, accuracy: 0.001)
    }

    func testClampsToSelectionBounds() {
        let rects = PrivacyMaskGeometry.canvasRects(
            regions: [
                SensitiveRegion(
                    rect: CGRect(x: 0, y: 0, width: 200, height: 200),
                    kind: "人脸",
                    preview: "人脸"
                )
            ],
            activeRegion: CGRect(x: 20, y: 20, width: 60, height: 60),
            displayFrame: CGRect(x: 0, y: 0, width: 100, height: 100),
            scale: 1
        )
        XCTAssertEqual(rects.count, 1)
        XCTAssertEqual(rects[0].maxX, 80, accuracy: 0.001)
        XCTAssertEqual(rects[0].maxY, 80, accuracy: 0.001)
    }

    func testRejectsInvalidScale() {
        XCTAssertTrue(PrivacyMaskGeometry.canvasRects(
            regions: [],
            activeRegion: CGRect(x: 0, y: 0, width: 10, height: 10),
            displayFrame: .zero,
            scale: 0
        ).isEmpty)
    }
}

@MainActor
final class PrivacyMaskControlTests: XCTestCase {

    func testActivationPerformsPrivacyAction() {
        var performed: String?
        let context = ToolbarContext(
            annotation: AnnotationState(styleStore: FakeStyleStore()),
            scope: .capture,
            perform: { performed = $0 }
        )
        PrivacyMaskControl().activate(context)
        XCTAssertEqual(performed, ActionID.privacyMask)
    }

    func testBusyReflectsExecutionState() {
        let context = ToolbarContext(
            annotation: AnnotationState(styleStore: FakeStyleStore()),
            scope: .capture,
            perform: { _ in },
            isActionExecuting: { $0 == ActionID.privacyMask }
        )
        XCTAssertTrue(PrivacyMaskControl().isBusy(context))
    }
}
