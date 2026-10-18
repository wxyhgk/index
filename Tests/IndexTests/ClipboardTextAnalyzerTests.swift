import XCTest
@testable import IndexApp

final class ClipboardTextAnalyzerTests: XCTestCase {

    // MARK: - URL 提取

    func testExtractsSingleURL() {
        let text = "https://github.com/apple/swift"
        let urls = ClipboardTextAnalyzer.extractURLs(from: text)
        XCTAssertEqual(urls, ["https://github.com/apple/swift"])
    }

    func testExtractsMultipleURLs() {
        let text = """
        参考 https://docs.swift.org 和 https://github.com/apple/swift
        """
        let urls = ClipboardTextAnalyzer.extractURLs(from: text)
        XCTAssertEqual(urls.count, 2)
    }

    func testIgnoresShortURLs() {
        let text = "https://a.co"
        let urls = ClipboardTextAnalyzer.extractURLs(from: text)
        XCTAssertTrue(urls.isEmpty, "太短的 URL 不应提取")
    }

    func testStripsTrailingPunctuation() {
        let text = "详见 https://example.com/page。"
        let urls = ClipboardTextAnalyzer.extractURLs(from: text)
        XCTAssertEqual(urls, ["https://example.com/page"])
    }

    func testDeduplicatesByNormalizedURL() {
        let text = """
        https://example.com/page?utm_source=twitter&utm_medium=social
        https://example.com/page
        """
        let urls = ClipboardTextAnalyzer.extractURLs(from: text)
        XCTAssertEqual(urls.count, 1, "归一化后应去重")
    }

    // MARK: - URL 归一化

    func testNormalizeStripsTrackingParams() {
        let normalized = ClipboardTextAnalyzer.normalizeURL(
            "https://example.com?utm_source=twitter&fbclid=abc123&path=home"
        )
        XCTAssertFalse(normalized.contains("utm_source"))
        XCTAssertFalse(normalized.contains("fbclid"))
        XCTAssertTrue(normalized.contains("path=home"))
    }

    func testNormalizeStripsTrailingSlash() {
        let normalized = ClipboardTextAnalyzer.normalizeURL("https://example.com/")
        XCTAssertEqual(normalized, "https://example.com")
    }

    func testNormalizeKeepsNonTrackingParams() {
        let normalized = ClipboardTextAnalyzer.normalizeURL("https://example.com?a=1&b=2")
        XCTAssertTrue(normalized.contains("a=1"))
        XCTAssertTrue(normalized.contains("b=2"))
    }

    // MARK: - 代码块检测

    func testDetectsFencedCodeBlock() {
        let text = """
        这是说明文字
        ```swift
        let x = 42
        ```
        后面还有文字
        """
        let blocks = ClipboardTextAnalyzer.detectCodeBlocks(in: text)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].language, "swift")
        XCTAssertTrue(blocks[0].content.contains("let x = 42"))
    }

    func testDetectsMultipleFencedBlocks() {
        let text = """
        ```python
        print("hello")
        ```
        中间文字
        ```sql
        SELECT * FROM users
        ```
        """
        let blocks = ClipboardTextAnalyzer.detectCodeBlocks(in: text)
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[0].language, "python")
        XCTAssertEqual(blocks[1].language, "sql")
    }

    func testDetectsUnfencedCode() {
        let text = "import SwiftUI\nstruct Card: View { var body: some View { Text(\"hi\") } }"
        let blocks = ClipboardTextAnalyzer.detectCodeBlocks(in: text)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].language, "swift")
    }

    func testNoCodeInProse() {
        let text = "这是一段普通的中文文字，不应该被识别为代码。"
        let blocks = ClipboardTextAnalyzer.detectCodeBlocks(in: text)
        XCTAssertTrue(blocks.isEmpty)
    }

    // MARK: - 分类

    func testPlainText() {
        let analysis = ClipboardTextAnalyzer.analyze("今天天气不错")
        XCTAssertEqual(analysis.category, .plain)
        XCTAssertTrue(analysis.tags.isEmpty)
    }

    func testPureURL() {
        let analysis = ClipboardTextAnalyzer.analyze("https://github.com/apple/swift")
        XCTAssertEqual(analysis.category, .url)
        XCTAssertTrue(analysis.tags.contains("url"))
    }

    func testMixedTextWithURL() {
        let text = "参考这个文档：https://docs.swift.org 然后按步骤操作"
        let analysis = ClipboardTextAnalyzer.analyze(text)
        XCTAssertEqual(analysis.category, .mixed)
        XCTAssertTrue(analysis.tags.contains("url"))
    }

    func testCode() {
        let text = "def hello():\n    print('world')"
        let analysis = ClipboardTextAnalyzer.analyze(text)
        XCTAssertEqual(analysis.category, .code)
        XCTAssertTrue(analysis.tags.contains { $0.hasPrefix("code:") })
    }

    func testMixedCodeAndURL() {
        let text = """
        看这个 issue：https://github.com/some/repo/issues/42
        ```swift
        let x = 1
        ```
        """
        let analysis = ClipboardTextAnalyzer.analyze(text)
        XCTAssertEqual(analysis.category, .mixed)
        XCTAssertTrue(analysis.tags.contains("url"))
        XCTAssertTrue(analysis.tags.contains { $0.hasPrefix("code:") })
    }

    // MARK: - tags 生成

    func testTagsSorted() {
        let text = """
        看 https://github.com/some/repo
        ```python
        x = 1
        ```
        """
        let analysis = ClipboardTextAnalyzer.analyze(text)
        let tags = analysis.tags
        XCTAssertEqual(tags, tags.sorted(), "tags 应该排序")
        XCTAssertTrue(tags.contains("url"))
    }

    // MARK: - hasTag

    func testHasTagMatchesExact() {
        let item = makeItem(tags: #"["url","code:swift"]"#)
        XCTAssertTrue(item.hasTag("url"))
        XCTAssertTrue(item.hasTag("code:swift"))
        XCTAssertFalse(item.hasTag("image"))
    }

    func testHasTagMatchesPrefix() {
        let item = makeItem(tags: #"["code:swift","code:python"]"#)
        XCTAssertTrue(item.hasTag("code"), "code 应匹配 code:swift 和 code:python")
        XCTAssertFalse(item.hasTag("url"))
    }

    func testHasTagReturnsFalseForNil() {
        let item = makeItem(tags: nil)
        XCTAssertFalse(item.hasTag("url"))
        XCTAssertFalse(item.hasTag("code"))
    }

    func testHasTagReturnsFalseForInvalidJSON() {
        let item = makeItem(tags: "not json")
        XCTAssertFalse(item.hasTag("url"))
    }

    // MARK: - 辅助

    private func makeItem(tags: String?) -> ClipboardHistoryItem {
        ClipboardHistoryItem(
            id: 1,
            kind: .text,
            contentHash: "test",
            text: "test",
            assetPath: nil,
            summary: "test",
            sourceApp: nil,
            pinned: false,
            capturedAt: Date(),
            lastUsedAt: nil,
            title: nil,
            isFavorite: false,
            tags: tags
        )
    }
}
