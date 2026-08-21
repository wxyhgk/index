import CoreGraphics
import XCTest
@testable import IndexApp

final class StepGuideExporterTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("StepGuideTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
        super.tearDown()
    }

    private func grayImage(_ value: UInt8, size: Int = 32) -> CGImage {
        let data = [UInt8](repeating: value, count: size * size)
        let context = CGContext(
            data: nil,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: size,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        )!
        data.withUnsafeBytes { buffer in
            context.data?.copyMemory(from: buffer.baseAddress!, byteCount: buffer.count)
        }
        return context.makeImage()!
    }

    func testExportWritesMarkdownAndPNGs() throws {
        let steps = [
            StepGuideStep(image: grayImage(10), caption: "步骤 1"),
            StepGuideStep(image: grayImage(120), caption: "步骤 2"),
        ]
        let guide = try StepGuideExporter.export(
            steps: steps,
            sourceName: "20260820-120000.mp4",
            destination: tempDir
        )

        XCTAssertEqual(guide.stepCount, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: guide.markdownURL.path))
        for name in ["step-01.png", "step-02.png"] {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: guide.directory.appendingPathComponent(name).path),
                "缺少 \(name)"
            )
        }

        let markdown = try String(contentsOf: guide.markdownURL, encoding: .utf8)
        XCTAssertTrue(markdown.hasPrefix("# 步骤指南"))
        XCTAssertTrue(markdown.contains("> 来源：20260820-120000.mp4 · 共 2 步"))
        XCTAssertTrue(markdown.contains("## 步骤 1"))
        XCTAssertTrue(markdown.contains("![步骤 1](step-01.png)"))
        XCTAssertTrue(markdown.contains("步骤 1"))
        XCTAssertTrue(markdown.contains("![步骤 2](step-02.png)"))
    }

    func testExportWithoutSourceNameOmitsSourceLine() {
        let markdown = StepGuideExporter.renderMarkdown(
            steps: [StepGuideStep(image: grayImage(1), caption: "步骤 1")],
            sourceName: nil
        )
        XCTAssertFalse(markdown.contains("来源"))
        XCTAssertTrue(markdown.contains("## 步骤 1"))
    }

    func testExportEmptyStepsThrowsAndLeavesNoFolder() {
        XCTAssertThrowsError(
            try StepGuideExporter.export(steps: [], sourceName: nil, destination: tempDir)
        ) { error in
            XCTAssertEqual(error as? StepGuideError, .noSteps)
        }
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: tempDir.path)) ?? []
        XCTAssertTrue(contents.isEmpty, "空步骤不应留下文件夹")
    }

    func testFolderNameFormat() {
        let date = Date(timeIntervalSince1970: 0) // 1970-01-01 00:00:00 UTC
        let name = StepGuideExporter.folderName(for: date)
        // 时区相关，只校验前缀与长度形态。
        XCTAssertTrue(name.hasPrefix("步骤指南-"))
        XCTAssertEqual(name.count, "步骤指南-".count + 15)
    }
}
