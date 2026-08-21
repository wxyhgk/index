import CoreGraphics
import XCTest
@testable import IndexApp

@MainActor
final class ShelfLifecycleTests: XCTestCase {

    func testShelfPreviewBoundsDecodedPixels() throws {
        let source = try makeImage(width: 2_000, height: 1_000)

        let preview = ShelfController.makePreview(from: source)

        XCTAssertEqual(preview.width, 480)
        XCTAssertEqual(preview.height, 240)
    }

    func testSmallShelfPreviewReusesSource() throws {
        let source = try makeImage(width: 320, height: 200)

        XCTAssertTrue(ShelfController.makePreview(from: source) === source)
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
        context.setFillColor(CGColor(gray: 0.25, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }
}
