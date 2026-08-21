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
