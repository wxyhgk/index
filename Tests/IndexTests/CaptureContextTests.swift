import CoreGraphics
import XCTest
@testable import IndexApp

@MainActor
final class CaptureContextTests: XCTestCase {

    func testRenderedArtifactIsSharedAcrossContextCopies() throws {
        let base = try makeImage(width: 32, height: 24)
        let layers = Layers<ImageSpace>([
            Layer(
                kind: .rect,
                rect: LRect(x: 2, y: 2, w: 12, h: 8),
                color: .red,
                lineWidth: 2
            )
        ])
        let context = CaptureContext(
            base: base,
            layers: layers,
            shot: nil,
            region: nil,
            host: nil
        )
        let copiedContext = context

        let first = context.rendered()
        let second = copiedContext.rendered()

        XCTAssertTrue(first === second, "一次捕获的多个消费者应复用同一张成品位图")
    }

    func testEmptyLayersReturnOriginalImage() throws {
        let base = try makeImage(width: 8, height: 8)
        let context = CaptureContext(
            base: base,
            layers: Layers<ImageSpace>(),
            shot: nil,
            region: nil,
            host: nil
        )

        XCTAssertTrue(context.rendered() === base)
    }

    private func makeImage(width: Int, height: Int) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }
}
