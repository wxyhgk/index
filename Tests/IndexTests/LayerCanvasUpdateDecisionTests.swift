import CoreGraphics
import XCTest
@testable import IndexApp

final class LayerCanvasUpdateDecisionTests: XCTestCase {
    func testIdenticalVisualInputsDoNotRedraw() throws {
        let image = try makeImage(gray: 0.2)
        let preview = try makeImage(gray: 0.5)
        let previewID = UUID()
        let snapshot = makeSnapshot(
            image: image,
            previews: [previewID: preview]
        )

        let decision = LayerCanvasUpdateDecision.compare(
            previous: snapshot,
            current: makeSnapshot(image: image, previews: [previewID: preview])
        )

        XCTAssertFalse(decision.needsDisplay)
        XCTAssertFalse(decision.needsLiveTextSync)
    }

    func testNewBottomImageRedrawsAndResynchronizesLiveText() throws {
        let previous = makeSnapshot(image: try makeImage(gray: 0.2))
        let current = makeSnapshot(image: try makeImage(gray: 0.2))

        let decision = LayerCanvasUpdateDecision.compare(previous: previous, current: current)

        XCTAssertTrue(decision.imageChanged)
        XCTAssertTrue(decision.needsDisplay)
        XCTAssertTrue(decision.needsLiveTextSync)
    }

    func testLayerAndSelectionChangesRedrawWithoutLiveTextWork() throws {
        let image = try makeImage(gray: 0.2)
        let previous = makeSnapshot(image: image)
        let selectedID = UUID()
        let layers = Layers<ImageSpace>([
            Layer(id: selectedID, kind: .rect, rect: LRect(x: 1, y: 2, w: 3, h: 4))
        ])
        let current = makeSnapshot(image: image, layers: layers, selectedLayerID: selectedID)

        let decision = LayerCanvasUpdateDecision.compare(previous: previous, current: current)

        XCTAssertTrue(decision.layersChanged)
        XCTAssertTrue(decision.selectionChanged)
        XCTAssertTrue(decision.needsDisplay)
        XCTAssertFalse(decision.needsLiveTextSync)
    }

    func testReplacingPixelatePreviewRedrawsWithoutLiveTextWork() throws {
        let image = try makeImage(gray: 0.2)
        let previewID = UUID()
        let previous = makeSnapshot(
            image: image,
            previews: [previewID: try makeImage(gray: 0.4)]
        )
        let current = makeSnapshot(
            image: image,
            previews: [previewID: try makeImage(gray: 0.6)]
        )

        let decision = LayerCanvasUpdateDecision.compare(previous: previous, current: current)

        XCTAssertTrue(decision.previewsChanged)
        XCTAssertTrue(decision.needsDisplay)
        XCTAssertFalse(decision.needsLiveTextSync)
    }

    func testLiveResizeUsesLowInterpolationAndRestoresHighQuality() {
        XCTAssertEqual(CanvasInterpolationPolicy.quality(isLiveResizing: true), .low)
        XCTAssertEqual(CanvasInterpolationPolicy.quality(isLiveResizing: false), .high)
    }

    func testLiveTextOnlyParticipatesInIdlePointerMode() {
        XCTAssertTrue(LayerCanvasInteractionPolicy.allowsLiveText(
            annotationToolActive: false,
            handModeActive: false
        ))
        XCTAssertFalse(LayerCanvasInteractionPolicy.allowsLiveText(
            annotationToolActive: true,
            handModeActive: false
        ))
        XCTAssertFalse(LayerCanvasInteractionPolicy.allowsLiveText(
            annotationToolActive: false,
            handModeActive: true
        ))
    }

    func testAnnotationPointerCaptureMakesCanvasTheHitTarget() throws {
        let view = CanvasView(frame: CGRect(x: 0, y: 0, width: 400, height: 200))
        view.image = try makeImage(width: 100, height: 50)
        view.capturesAnnotationPointerEvents = true

        XCTAssertTrue(view.hitTest(CGPoint(x: 200, y: 100)) === view)
        XCTAssertNil(view.hitTest(CGPoint(x: 401, y: 100)))
        XCTAssertEqual(
            view.imagePixelPoint(fromViewLocal: CGPoint(x: 200, y: 100)),
            CGPoint(x: 50, y: 25)
        )
    }

    private func makeSnapshot(
        image: CGImage,
        layers: Layers<ImageSpace> = Layers(),
        previews: [UUID: CGImage] = [:],
        selectedLayerID: UUID? = nil
    ) -> LayerCanvasVisualSnapshot {
        LayerCanvasVisualSnapshot(
            image: image,
            layers: layers,
            pixelatePreviews: previews,
            selectedLayerID: selectedLayerID
        )
    }

    private func makeImage(gray: CGFloat) throws -> CGImage {
        try makeImage(width: 4, height: 4, gray: gray)
    }

    private func makeImage(
        width: Int,
        height: Int,
        gray: CGFloat = 0.2
    ) throws -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(red: gray, green: gray, blue: gray, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }
}
