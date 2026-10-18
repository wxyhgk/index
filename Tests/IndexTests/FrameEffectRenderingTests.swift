import XCTest
import AppKit
import CoreGraphics
@testable import IndexApp

@MainActor
final class FrameEffectRenderingTests: XCTestCase {

    private func base(width: Int, height: Int) -> CGImage {
        let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    private func frameLayer(style: FrameSpec.Style, scale: CGFloat) -> Layer {
        var spec = FrameSpec()
        spec.style = style
        spec.title = "Index"
        var layer = Layer(
            kind: .frame,
            rect: LRect(x: 0, y: 0, w: 0, h: 0),
            color: .red,
            lineWidth: Double(scale)
        )
        layer.text = spec.json
        return layer
    }

    func testMacOSShellAddsTitleBarAtScale() {
        let input = base(width: 200, height: 100)
        let output = LayerRenderer.render(
            base: input,
            layers: Layers<ImageSpace>([frameLayer(style: .macos, scale: 2)])
        )
        XCTAssertEqual(output.width, 200)
        XCTAssertEqual(output.height, 100 + Int(28 * 2))
    }

    func testBrowserShellAddsTitleAndURLBars() {
        let input = base(width: 200, height: 100)
        let output = LayerRenderer.render(
            base: input,
            layers: Layers<ImageSpace>([frameLayer(style: .browser, scale: 2)])
        )
        XCTAssertEqual(output.width, 200)
        XCTAssertEqual(output.height, 100 + Int((28 + 32) * 2))
    }
}
