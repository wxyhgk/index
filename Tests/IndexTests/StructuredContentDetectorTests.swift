import XCTest
@testable import IndexApp

// MARK: - 结构化内容检测单测
//
// 颜色检测（同步，纯像素）+ URL 检测（纯文本）+ 文本/图片兜底。
// OCR 路径用真实 Vision（慢但准），只测确定性部分。

final class StructuredContentDetectorTests: XCTestCase {

    // MARK: 颜色检测

    func test_detectsSolidColor() async {
        // 100×100 纯红色方块
        let image = makeSolidImage(width: 100, height: 100, r: 255, g: 0, b: 0)
        let result = await StructuredContentDetector.detect(in: image)
        XCTAssertEqual(result, .color(hex: "#FF0000"))
    }

    func test_detectsSmallColorSquare() async {
        // 50×50 纯蓝色
        let image = makeSolidImage(width: 50, height: 50, r: 0, g: 0, b: 255)
        let result = await StructuredContentDetector.detect(in: image)
        XCTAssertEqual(result, .color(hex: "#0000FF"))
    }

    func test_largeImageIsNotColor() async {
        // 500×500 纯色，但超过 200px 阈值 → 不走颜色路径
        // OCR 对纯色图返回空 → 兜底 .image
        let image = makeSolidImage(width: 500, height: 500, r: 128, g: 128, b: 128)
        let result = await StructuredContentDetector.detect(in: image)
        XCTAssertEqual(result, .image)
    }

    func test_noisyImageIsNotColor() async {
        // 100×100 但颜色不均匀（棋盘格）→ 方差大 → 不是色块
        let image = makeCheckerboardImage(width: 100, height: 100)
        let result = await StructuredContentDetector.detect(in: image)
        // 棋盘格 OCR 也识别不出文字 → .image
        XCTAssertEqual(result, .image)
    }

    // MARK: URL 检测

    func test_detectsURL() async {
        // 渲染一张带 URL 文字的图（加大尺寸和字体，保证 OCR 能识别）
        let image = makeTextImage(text: "https://example.com/page", width: 600, height: 100)
        let result = await StructuredContentDetector.detect(in: image)
        guard case .url(let url) = result else {
            return XCTFail("Expected .url, got \(result)")
        }
        XCTAssertTrue(url.hasPrefix("https://example.com"))
    }

    // MARK: 文本检测

    func test_detectsPlainText() async {
        let image = makeTextImage(text: "Hello World", width: 500, height: 100)
        let result = await StructuredContentDetector.detect(in: image)
        guard case .text(let text) = result else {
            return XCTFail("Expected .text, got \(result)")
        }
        XCTAssertTrue(text.lowercased().contains("hello"))
    }

    // MARK: 图片兜底

    func test_gradientImageFallsBackToImage() async {
        // 渐变图：不是纯色（方差大），OCR 识别不出文字 → .image
        let image = makeGradientImage(width: 300, height: 300)
        let result = await StructuredContentDetector.detect(in: image)
        XCTAssertEqual(result, .image)
    }

    // MARK: 工具：造测试图

    private func makeSolidImage(width: Int, height: Int, r: Int, g: Int, b: Int) -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bytesPerRow = width * 4
        var data = [UInt8](repeating: 0, count: height * bytesPerRow)
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * bytesPerRow + x * 4
                data[offset] = UInt8(r)       // R
                data[offset + 1] = UInt8(g)   // G
                data[offset + 2] = UInt8(b)   // B
                data[offset + 3] = 255        // A
            }
        }
        return CGImage(
            width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: CGDataProvider(data: Data(data) as CFData)!,
            decode: nil, shouldInterpolate: false,
            intent: .defaultIntent
        )!
    }

    private func makeCheckerboardImage(width: Int, height: Int) -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bytesPerRow = width * 4
        var data = [UInt8](repeating: 0, count: height * bytesPerRow)
        let cellSize = 10
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * bytesPerRow + x * 4
                let isBlack = ((x / cellSize) + (y / cellSize)) % 2 == 0
                let v: UInt8 = isBlack ? 0 : 255
                data[offset] = v
                data[offset + 1] = v
                data[offset + 2] = v
                data[offset + 3] = 255
            }
        }
        return CGImage(
            width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: CGDataProvider(data: Data(data) as CFData)!,
            decode: nil, shouldInterpolate: false,
            intent: .defaultIntent
        )!
    }

    private func makeGradientImage(width: Int, height: Int) -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bytesPerRow = width * 4
        var data = [UInt8](repeating: 0, count: height * bytesPerRow)
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * bytesPerRow + x * 4
                data[offset] = UInt8(x * 255 / max(1, width - 1))   // R 渐变
                data[offset + 1] = UInt8(y * 255 / max(1, height - 1)) // G 渐变
                data[offset + 2] = 128
                data[offset + 3] = 255
            }
        }
        return CGImage(
            width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: CGDataProvider(data: Data(data) as CFData)!,
            decode: nil, shouldInterpolate: false,
            intent: .defaultIntent
        )!
    }

    /// 用 NSImage 渲染一张带文字的图（OCR 能识别）。
    private func makeTextImage(text: String, width: Int, height: Int) -> CGImage {
        let size = NSSize(width: width, height: height)
        let image = NSImage(size: size)
        image.lockFocus()
        // 白底
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        // 黑字（NSImage 坐标系原点在左下，文字正常方向）
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 36, weight: .medium),
            .foregroundColor: NSColor.black
        ]
        let attrStr = NSAttributedString(string: text, attributes: attrs)
        let textSize = attrStr.size()
        let textOrigin = CGPoint(x: 10, y: (CGFloat(height) - textSize.height) / 2)
        attrStr.draw(at: textOrigin)
        image.unlockFocus()
        // 转 CGImage
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let cgImage = rep.cgImage else {
            return makeSolidImage(width: width, height: height, r: 255, g: 255, b: 255)
        }
        return cgImage
    }
}
