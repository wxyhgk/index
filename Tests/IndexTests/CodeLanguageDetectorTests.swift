import XCTest
@testable import IndexApp

final class CodeLanguageDetectorTests: XCTestCase {
    func testDetectsCommonLanguagesWithoutNetworkOrParsingServices() {
        XCTAssertEqual(CodeLanguageDetector.detect("{\"enabled\": true}"), "json")
        XCTAssertEqual(CodeLanguageDetector.detect("import SwiftUI\nstruct Card: View {}"), "swift")
        XCTAssertEqual(CodeLanguageDetector.detect("def greet(name):\n    print(name)"), "python")
        XCTAssertEqual(CodeLanguageDetector.detect("const greet = (name) => console.log(name)"), "javascript")
        XCTAssertEqual(CodeLanguageDetector.detect("interface User { name: string }"), "typescript")
        XCTAssertEqual(CodeLanguageDetector.detect("fn main() { let mut count = 0; }"), "rust")
        XCTAssertEqual(CodeLanguageDetector.detect("SELECT name FROM users"), "sql")
        XCTAssertEqual(CodeLanguageDetector.detect("#!/bin/zsh\nset -e"), "shell")
    }

    func testEmptyAndOrdinaryProseStayUnclassified() {
        XCTAssertNil(CodeLanguageDetector.detect("  \n"))
        XCTAssertNil(CodeLanguageDetector.detect("这是一段普通文字，不应该猜成代码。"))
    }

    func testPreviewBoundsWorkForVeryLargeSnippets() {
        let source = String(repeating: "x", count: CodePreview.characterLimit * 2)
        let preview = CodePreview(content: ContentCode(contentID: 1, language: "swift", text: source))

        XCTAssertEqual(preview.text.count, CodePreview.characterLimit)
        XCTAssertEqual(preview.language, "swift")
    }
}
