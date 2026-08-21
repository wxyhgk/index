import XCTest
import CoreGraphics
@testable import IndexApp

/// 绘制搬家的安全网。
///
/// 逐层绘制从 `LayerRenderer` 的一个 `switch layer.kind` 加七个私有函数，
/// 搬进了各工具的描述符。绘制代码是最容易「搬完看起来没事、实际少画了一笔」的
/// 地方，而且原先**一条测试都没有**——所以这里直接验像素。
final class ToolDrawingTests: XCTestCase {

    /// 32×32 纯白底图。坐标一律左上原点（与 `Layer.rect` 一致）。
    private func whiteBase(_ side: Int = 32) -> CGImage {
        let ctx = CGContext(
            data: nil, width: side, height: side,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        return ctx.makeImage()!
    }

    /// 取某点的 RGBA（左上原点）。
    private func pixel(_ image: CGImage, x: Int, y: Int) -> (r: Int, g: Int, b: Int, a: Int) {
        let width = image.width
        let height = image.height
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let ctx = CGContext(
            data: &buffer, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        // 缓冲区的行号**就是**图层坐标的 y（左上原点）—— `render` 已经把上下文翻过一次，
        // 这里再翻一次就翻回去了。实测确认：rect(0, 20, 8, 8) 的高亮正好落在第 20…27 行。
        let offset = (y * width + x) * 4
        return (Int(buffer[offset]), Int(buffer[offset + 1]),
                Int(buffer[offset + 2]), Int(buffer[offset + 3]))
    }

    private func render(_ layers: [Layer], side: Int = 32) -> CGImage {
        LayerRenderer.render(base: whiteBase(side), layers: Layers<ImageSpace>(layers))
    }

    private func layer(_ kind: Layer.Kind, _ rect: CGRect, lineWidth: Double = 4) -> Layer {
        Layer(kind: kind, rect: LRect(rect), color: .red, lineWidth: lineWidth)
    }

    // MARK: - 逐层绘制确实发生了

    /// 矩形描边：边上有红、正中仍是白（描边不是填充）。
    func testRectStrokesOutlineNotFill() {
        let image = render([layer(.rect, CGRect(x: 8, y: 8, width: 16, height: 16))])

        let onEdge = pixel(image, x: 16, y: 8)
        XCTAssertGreaterThan(onEdge.r, onEdge.g + 40, "边框应该是红的，实得 \(onEdge)")

        let inside = pixel(image, x: 16, y: 16)
        XCTAssertEqual(inside.g, 255, "矩形内部不该被填充，实得 \(inside)")
    }

    /// 高亮是正片叠底填充：内部被染色。
    func testHighlightFillsInterior() {
        var highlight = layer(.highlight, CGRect(x: 8, y: 8, width: 16, height: 16))
        highlight.color.a = 0.4
        let image = render([highlight])

        let inside = pixel(image, x: 16, y: 16)
        XCTAssertLessThan(inside.g, 250, "高亮应该染到内部，实得 \(inside)")
    }

    /// 椭圆画的是椭圆而不是矩形：角上应保持空白。
    func testEllipseLeavesCornersUntouched() {
        let image = render([layer(.ellipse, CGRect(x: 4, y: 4, width: 24, height: 24))])

        let corner = pixel(image, x: 5, y: 5)
        XCTAssertEqual(corner.g, 255, "椭圆不该画到外接矩形的角上，实得 \(corner)")
    }

    /// 序号徽章是实心圆 + 白字：圆心区域被填成红，四角保持白。
    func testCounterFillsCircleAndCornersStayClear() {
        var badge = layer(.counter, CGRect(x: 4, y: 4, width: 24, height: 24))
        badge.text = "1"
        badge.fontSize = 12
        let image = render([badge])

        let corner = pixel(image, x: 5, y: 5)
        XCTAssertEqual(corner.g, 255, "徽章是圆的，角上不该有颜色，实得 \(corner)")

        // 圆内偏离中心处（避开白色数字本身）应是红底。
        let onDisc = pixel(image, x: 16, y: 7)
        XCTAssertGreaterThan(onDisc.r, onDisc.g + 40, "圆内应是实心红，实得 \(onDisc)")
    }

    /// 文字要真的画出笔画来。
    func testTextDrawsGlyphs() {
        var text = layer(.text, CGRect(x: 2, y: 2, width: 0, height: 0))
        text.text = "MMMM"
        text.fontSize = 20
        let image = render([text])

        let painted = (0..<32).contains { x in
            (0..<32).contains { y in
                let p = pixel(image, x: x, y: y)
                return p.r > p.g + 40
            }
        }
        XCTAssertTrue(painted, "文字应该画出可见笔画")
    }

    // MARK: - 合并绘制（聚光灯）

    /// 聚光灯：亮区内保持原样，区外被压暗 —— 这是 `drawsMerged` 那条路径。
    func testSpotlightDimsOutsideOnly() {
        var spotlight = layer(.spotlight, CGRect(x: 8, y: 8, width: 16, height: 16))
        spotlight.dim = 0.6
        let image = render([spotlight])

        let inside = pixel(image, x: 16, y: 16)
        XCTAssertEqual(inside.g, 255, "亮区内不该被压暗，实得 \(inside)")

        let outside = pixel(image, x: 2, y: 2)
        XCTAssertLessThan(outside.g, 150, "区外应被压暗，实得 \(outside)")
    }

    /// 两个聚光灯重叠时交集仍然是亮的（挖洞而不是 even-odd）。
    func testOverlappingSpotlightsKeepIntersectionBright() {
        var a = layer(.spotlight, CGRect(x: 4, y: 4, width: 16, height: 16))
        a.dim = 0.6
        var b = layer(.spotlight, CGRect(x: 12, y: 12, width: 16, height: 16))
        b.dim = 0.6
        let image = render([a, b])

        let intersection = pixel(image, x: 16, y: 16)
        XCTAssertEqual(intersection.g, 255, "两个亮区的交集必须仍然是亮的，实得 \(intersection)")
    }

    /// 聚光灯画在其余矢量层**之下** —— 标注本身不该被压暗。
    func testSpotlightDoesNotDimAnnotationsAboveIt() {
        var spotlight = layer(.spotlight, CGRect(x: 0, y: 0, width: 8, height: 8))
        spotlight.dim = 0.6
        // 矩形整个落在亮区之外，若顺序错了它会被那层黑纱盖住。
        let box = layer(.rect, CGRect(x: 12, y: 12, width: 12, height: 12), lineWidth: 4)
        let image = render([spotlight, box])

        let onEdge = pixel(image, x: 18, y: 12)
        XCTAssertGreaterThan(onEdge.r, 180, "标注应压在遮罩之上，实得 \(onEdge)")
    }

    // MARK: - 不逐层绘制的那些

    /// 裁剪不画任何东西，只改画布尺寸。
    func testCropCutsCanvasAndDrawsNothing() {
        let image = render([layer(.crop, CGRect(x: 0, y: 0, width: 16, height: 16))])

        XCTAssertEqual(image.width, 16)
        XCTAssertEqual(image.height, 16)
        let inside = pixel(image, x: 8, y: 8)
        XCTAssertEqual(inside.g, 255, "裁剪不该在画布上留下笔迹，实得 \(inside)")
    }

    /// 马赛克是图像级滤镜，不是矢量描边 —— 不该画出红色轮廓。
    func testPixelateDrawsNoOutline() {
        let image = render([layer(.pixelate, CGRect(x: 8, y: 8, width: 16, height: 16))])

        let onEdge = pixel(image, x: 16, y: 8)
        XCTAssertLessThan(onEdge.r, onEdge.g + 40, "马赛克不该有描边，实得 \(onEdge)")
    }

    // MARK: - 编排

    /// 效果层没有画布形体，不参与逐层绘制（注册表里也查不到它们）。
    func testEffectLayersAreNotVectorDrawn() {
        for kind in Layer.Kind.allCases where kind.isEffect {
            XCTAssertNil(
                ToolRegistry.descriptor(for: kind),
                "\(kind) 是效果层，不该有工具描述符"
            )
        }
    }

    /// 只有聚光灯声明了合并绘制 —— 多一个就意味着有人在往编排里塞特例。
    func testOnlySpotlightDrawsMerged() {
        let merged = ToolRegistry.descriptors.filter(\.drawsMerged).map(\.tool)
        XCTAssertEqual(merged, [.spotlight])
    }
}
