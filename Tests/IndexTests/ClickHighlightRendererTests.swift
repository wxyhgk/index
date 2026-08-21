import CoreGraphics
import XCTest
@testable import IndexApp

final class ClickHighlightRendererTests: XCTestCase {

    /// 构造一张纯色灰图（灰度，1 字节/像素）。高亮渲染器画进 RGB context 时
    /// 会自动灰度→RGB 转换，角落 r==g==b 断言依然成立。
    private func grayImage(_ value: UInt8, width: Int, height: Int) -> CGImage {
        var data = [UInt8](repeating: value, count: width * height)
        return data.withUnsafeMutableBytes { buffer -> CGImage in
            let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            )!
            return context.makeImage()!
        }
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) -> (r: Int, g: Int, b: Int) {
        let width = image.width
        let height = image.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        return data.withUnsafeMutableBytes { buffer -> (r: Int, g: Int, b: Int) in
            let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            // context 坐标左下原点；转成左上原点 (x, y)。
            let index = ((height - 1 - y) * width + x) * 4
            return (Int(buffer[index]), Int(buffer[index + 1]), Int(buffer[index + 2]))
        }
    }

    /// 点击在选区中心：高亮圈落在帧中心，角落像素保持原灰度。
    func testHighlightAtRegionCenter() {
        let region = CGRect(x: 0, y: 0, width: 100, height: 100) // 点
        let scale: CGFloat = 2 // 帧 200x200
        let image = grayImage(128, width: 200, height: 200)
        let click = CGPoint(x: 50, y: 50) // 选区中心

        let highlighted = ClickHighlightRenderer.highlight(
            image: image,
            clickLocation: click,
            region: region,
            scale: scale
        )

        // 中心 (100,100) 应是红色系：R 明显高于 G/B。
        let center = pixel(highlighted, x: 100, y: 100)
        XCTAssertGreaterThan(center.r, center.g + 20, "中心应为红色高亮")
        XCTAssertGreaterThan(center.r, center.b + 20, "中心应为红色高亮")

        // 角落 (5,5) 应保持原灰度，不受影响。
        let corner = pixel(highlighted, x: 5, y: 5)
        XCTAssertEqual(corner.r, 128, accuracy: 8)
        XCTAssertEqual(corner.g, 128, accuracy: 8)
        XCTAssertEqual(corner.b, 128, accuracy: 8)
    }

    /// 点击在选区右上角：高亮圈落在帧右上角，左下角保持原灰度。
    func testHighlightAtRegionTopRight() {
        let region = CGRect(x: 0, y: 0, width: 100, height: 100)
        let scale: CGFloat = 2
        let image = grayImage(128, width: 200, height: 200)
        let click = CGPoint(x: 100, y: 100) // 选区右上角

        let highlighted = ClickHighlightRenderer.highlight(
            image: image,
            clickLocation: click,
            region: region,
            scale: scale
        )

        // 帧内应存在红色像素（圈的一部分在帧内）。
        var maxRedDelta = 0
        for y in stride(from: 0, to: 200, by: 2) {
            for x in stride(from: 0, to: 200, by: 2) {
                let p = pixel(highlighted, x: x, y: y)
                maxRedDelta = max(maxRedDelta, p.r - p.g)
            }
        }
        XCTAssertGreaterThan(maxRedDelta, 20, "帧内应出现红色高亮")

        // 左下角 (5,195) 远离右上角的圈，保持原灰度。
        let bottomLeft = pixel(highlighted, x: 5, y: 195)
        XCTAssertEqual(bottomLeft.r, 128, accuracy: 8)
        XCTAssertEqual(bottomLeft.g, 128, accuracy: 8)
        XCTAssertEqual(bottomLeft.b, 128, accuracy: 8)
    }

    /// 点击落在选区外：圈画到帧外，帧内像素基本不变。
    func testClickOutsideRegionLeavesFrameUnchanged() {
        let region = CGRect(x: 0, y: 0, width: 100, height: 100)
        let scale: CGFloat = 2
        let image = grayImage(128, width: 200, height: 200)
        let click = CGPoint(x: 500, y: 500) // 远在选区外

        let highlighted = ClickHighlightRenderer.highlight(
            image: image,
            clickLocation: click,
            region: region,
            scale: scale
        )

        let center = pixel(highlighted, x: 100, y: 100)
        XCTAssertEqual(center.r, 128, accuracy: 8)
        XCTAssertEqual(center.g, 128, accuracy: 8)
        XCTAssertEqual(center.b, 128, accuracy: 8)
    }
}
