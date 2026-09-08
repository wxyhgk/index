import AppKit
import CoreGraphics
import XCTest
@testable import IndexApp

final class MagnifierRendererTests: XCTestCase {

    /// 回归 2026-09-02 的闪退：放大镜高频重绘时，NSString/AppKit 的字体属性转换
    /// 曾抛出无法由 Swift 捕获的 NSInvalidArgumentException。这里直接对 CoreText 路径施压。
    @MainActor
    func testReadoutSurvivesRepeatedDrawing() throws {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: 232,
            height: 76,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let graphicsContext = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphicsContext
        defer { NSGraphicsContext.restoreGraphicsState() }

        let patch = try XCTUnwrap(context.makeImage())
        let sample = PixelSample(
            patch: patch,
            color: LColor(r: 0.25, g: 0.5, b: 0.75, a: 1),
            pixelPoint: CGPoint(x: 2_731, y: 2_047),
            patchSize: 21
        )

        for _ in 0..<2_000 {
            MagnifierRenderer.drawReadout(
                sample,
                in: CGRect(x: 0, y: 0, width: 116, height: 38),
                ctx: context
            )
        }

        XCTAssertNotNil(context.makeImage())
    }
}
