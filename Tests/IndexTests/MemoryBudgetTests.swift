import CoreGraphics
import XCTest
@testable import IndexApp

final class MemoryBudgetTests: XCTestCase {
    func testSharedTextAnalysisRunsAnalyzerOnlyOnceForConcurrentConsumers() async {
        let counter = LockedCounter()
        let expected = [VisionTextLine(text: "hello", rect: .zero)]
        let analysis = PostProcessAnalysis {
            counter.increment()
            try? await Task.sleep(for: .milliseconds(20))
            return expected
        }

        async let first = analysis.recognizedText()
        async let second = analysis.recognizedText()
        let values = await [first, second]

        XCTAssertEqual(values, [expected, expected])
        XCTAssertEqual(counter.value, 1)
    }

    func testSensitiveDetectorConsumesSharedTextLinesWithoutAnotherRecognition() {
        let line = VisionTextLine(
            candidates: ["token corrected-away", "token ghp_12345678901234567890"],
            rect: CGRect(x: 10, y: 20, width: 30, height: 40)
        )

        let regions = SensitiveContentDetector().sensitiveRegions(in: [line])

        XCTAssertEqual(regions.count, 1)
        XCTAssertEqual(regions.first?.kind, "GitHub 令牌")
        XCTAssertEqual(regions.first?.rect, line.rect)
        XCTAssertEqual(regions.first?.preview, "ghp_***")
    }

    func testPerCardScrollDepthHasHardBudget() {
        XCTAssertFalse(GalleryVisualBudget.allowsScrollDepth(isEnabled: false, cardCount: 1))
        XCTAssertFalse(GalleryVisualBudget.allowsScrollDepth(isEnabled: true, cardCount: 0))
        XCTAssertTrue(GalleryVisualBudget.allowsScrollDepth(isEnabled: true, cardCount: 60))
        XCTAssertFalse(GalleryVisualBudget.allowsScrollDepth(isEnabled: true, cardCount: 61))
    }

    func testEmptySensitiveResultStillProducesCompletionSentinel() throws {
        guard case .data(let payload, let searchableText)? =
            SensitiveContentProcessor.attributeValue(for: [])
        else {
            return XCTFail("空结果也必须生成属性")
        }

        XCTAssertNil(searchableText)
        XCTAssertEqual(try JSONDecoder().decode([SensitiveRegion].self, from: payload), [])
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func increment() {
        lock.lock()
        storage += 1
        lock.unlock()
    }
}
