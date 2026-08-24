import AppKit
import CoreGraphics
import VisionKit
import XCTest
@testable import IndexApp

@MainActor
final class CaptureLifecycleTests: XCTestCase {

    func testOverlayLiveTextTeardownCancelsAnalysisAndDetachesViews() {
        let host = LiveTextOverlayHost()
        let parent = NSView(frame: CGRect(x: 0, y: 0, width: 20, height: 20))
        let container = LiveTextHitTestView(frame: parent.bounds)
        let overlay = ImageAnalysisOverlayView(frame: container.bounds)
        container.addSubview(overlay)
        parent.addSubview(container)
        let task = Task { () -> ImageAnalysis? in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            return nil
        }
        host.container = container
        host.overlay = overlay
        host.analysis = (.zero, Layers(), task)

        host.teardown()

        XCTAssertTrue(task.isCancelled)
        XCTAssertNil(host.analysis)
        XCTAssertNil(host.container)
        XCTAssertNil(host.overlay)
        XCTAssertNil(container.superview)
    }

    func testPinLiveTextTeardownReleasesOverlayAndAnalysis() {
        let view = PinImageView(base: makeImage(), layers: Layers(), capture: FakeStyleStore(), annotationStyle: FakeStyleStore())
        view.enterLiveText()
        XCTAssertTrue(view.isLiveTextActive)
        XCTAssertTrue(view.hasLiveTextResources)

        view.teardownLiveText()

        XCTAssertFalse(view.isLiveTextActive)
        XCTAssertFalse(view.hasLiveTextResources)
    }

    func testPinCanvasOnlyRerendersWhenPixelateLayersChange() {
        let base = makeImage()
        let initialPixelate = Layer(
            kind: .pixelate,
            rect: LRect(CGRect(x: 1, y: 1, width: 3, height: 3))
        )
        var renderCount = 0
        let view = PinImageView(
            base: base,
            layers: Layers([initialPixelate]),
            capture: FakeStyleStore(),
            annotationStyle: FakeStyleStore(),
            canvasRenderer: { image, _ in
                renderCount += 1
                return image
            }
        )
        XCTAssertEqual(renderCount, 1)

        view.annotation.tool = .rect
        XCTAssertTrue(view.annotation.beginDraw(at: CGPoint(x: 1, y: 1)))
        XCTAssertTrue(view.annotation.updateDraw(to: CGPoint(x: 6, y: 6)))
        XCTAssertTrue(view.annotation.endDraw(pixelSource: { _ in nil }))
        view.commitAnnotationChange()
        XCTAssertEqual(renderCount, 1, "普通标注不应重新合成整张马赛克底图")

        view.annotation.tool = .pixelate
        XCTAssertTrue(view.annotation.beginDraw(at: CGPoint(x: 2, y: 2)))
        XCTAssertTrue(view.annotation.updateDraw(to: CGPoint(x: 7, y: 7)))
        XCTAssertTrue(view.annotation.endDraw(pixelSource: { _ in nil }))
        view.commitAnnotationChange()
        XCTAssertEqual(renderCount, 2, "马赛克集合变化后应恰好重算一次底图")
    }

    func testPinViewScalesBackingLayerInsteadOfRedrawingEveryResizeStep() {
        let view = PinImageView(
            base: makeImage(),
            layers: Layers(),
            capture: FakeStyleStore(),
            annotationStyle: FakeStyleStore()
        )

        XCTAssertEqual(view.layerContentsRedrawPolicy, .onSetNeedsDisplay)
        XCTAssertEqual(view.layerContentsPlacement, .scaleAxesIndependently)
    }

    private func makeImage() -> CGImage {
        let context = CGContext(
            data: nil,
            width: 8,
            height: 8,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return context.makeImage()!
    }
}
