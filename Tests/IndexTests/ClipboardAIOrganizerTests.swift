import XCTest
@testable import IndexApp

final class ClipboardAIOrganizerTests: XCTestCase {

    // MARK: - parseResponse

    @MainActor
    func testParseResponse_validJSON() {
        let response = """
        [
            {"id": 1, "title": "Swift 代码片段", "tags": ["code:swift"]},
            {"id": 2, "title": "GitHub 链接", "tags": ["url"]}
        ]
        """
        let results = ClipboardAIOrganizer.parseResponse(response, expectedIDs: [1, 2])
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0].id, 1)
        XCTAssertEqual(results[0].title, "Swift 代码片段")
        XCTAssertEqual(results[0].tags, ["code:swift"])
        XCTAssertEqual(results[1].id, 2)
        XCTAssertEqual(results[1].title, "GitHub 链接")
        XCTAssertEqual(results[1].tags, ["url"])
    }

    @MainActor
    func testParseResponse_markdownWrapped() {
        let response = """
        ```json
        [{"id": 1, "title": "测试标题", "tags": ["url", "secret"]}]
        ```
        """
        let results = ClipboardAIOrganizer.parseResponse(response, expectedIDs: [1])
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].id, 1)
        XCTAssertEqual(results[0].title, "测试标题")
        XCTAssertEqual(results[0].tags, ["url", "secret"])
    }

    @MainActor
    func testParseResponse_plainCodeBlock() {
        let response = """
        ```
        [{"id": 1, "title": "无语言标记", "tags": ["command"]}]
        ```
        """
        let results = ClipboardAIOrganizer.parseResponse(response, expectedIDs: [1])
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].tags, ["command"])
    }

    @MainActor
    func testParseResponse_filtersUnexpectedIDs() {
        let response = """
        [
            {"id": 1, "title": "有效", "tags": []},
            {"id": 999, "title": "无效 id", "tags": ["url"]}
        ]
        """
        let results = ClipboardAIOrganizer.parseResponse(response, expectedIDs: [1])
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].id, 1)
    }

    @MainActor
    func testParseResponse_invalidJSON() {
        let results = ClipboardAIOrganizer.parseResponse("这不是 JSON", expectedIDs: [1])
        XCTAssertEqual(results.count, 0)
    }

    @MainActor
    func testParseResponse_emptyArray() {
        let results = ClipboardAIOrganizer.parseResponse("[]", expectedIDs: [1])
        XCTAssertEqual(results.count, 0)
    }

    @MainActor
    func testParseResponse_missingTagsField() {
        let response = """
        [{"id": 1, "title": "无 tags 字段"}]
        """
        let results = ClipboardAIOrganizer.parseResponse(response, expectedIDs: [1])
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].tags, [])
    }

    @MainActor
    func testParseResponse_missingTitleField() {
        let response = """
        [{"id": 1, "tags": ["url"]}]
        """
        let results = ClipboardAIOrganizer.parseResponse(response, expectedIDs: [1])
        XCTAssertEqual(results.count, 1)
        XCTAssertNil(results[0].title)
    }

    // MARK: - buildPayload

    @MainActor
    func testBuildPayload_includesAllFields() {
        let items = [
            makeItem(id: 1, text: "hello world", source: "Safari"),
            makeItem(id: 2, text: "https://example.com", source: "Chrome")
        ]
        let payload = ClipboardAIOrganizer.buildPayload(from: items)
        XCTAssertTrue(payload.contains("hello world"))
        XCTAssertTrue(payload.contains("Safari"))
        // JSON 序列化会把 / 转义为 \/
        XCTAssertTrue(payload.contains("example.com"))
        XCTAssertTrue(payload.contains("Chrome"))
    }

    @MainActor
    func testBuildPayload_truncatesLongText() {
        let longText = String(repeating: "a", count: 1000)
        let items = [makeItem(id: 1, text: longText, source: nil)]
        let payload = ClipboardAIOrganizer.buildPayload(from: items)
        let aCount = payload.filter { $0 == "a" }.count
        XCTAssertLessThanOrEqual(aCount, 500)
    }

    @MainActor
    func testBuildPayload_skipsItemsWithoutID() {
        let items = [
            makeItem(id: nil, text: "无 id", source: nil),
            makeItem(id: 1, text: "有 id", source: nil)
        ]
        let payload = ClipboardAIOrganizer.buildPayload(from: items)
        XCTAssertFalse(payload.contains("无 id"))
        XCTAssertTrue(payload.contains("有 id"))
    }

    @MainActor
    func testBuildPayload_skipsItemsWithoutText() {
        let noText = ClipboardHistoryItem(
            id: 2, kind: .image, contentHash: "img01",
            text: nil, assetPath: "abc123.png", summary: "截图",
            sourceApp: nil, pinned: false, capturedAt: .now,
            lastUsedAt: nil, title: nil, isFavorite: false, tags: nil
        )
        let items = [noText]
        let payload = ClipboardAIOrganizer.buildPayload(from: items)
        // 图片条目没有 text，应该被跳过
        XCTAssertEqual(payload, "以下是用户最近复制的文本（JSON 数组），请分析：\n[]")
    }

    // MARK: - ClipboardHistoryPrefs 默认值

    func testClipboardHistoryPrefs_defaults() {
        let prefs = ClipboardHistoryPrefs.defaults
        XCTAssertTrue(prefs.enabled)
        XCTAssertEqual(prefs.retentionDays, 30)
        XCTAssertFalse(prefs.aiEnabled)
        XCTAssertEqual(prefs.aiHour, 22)
    }

    // MARK: - Helper

    @MainActor
    private func makeItem(id: Int64?, text: String?, source: String?) -> ClipboardHistoryItem {
        ClipboardHistoryItem(
            id: id, kind: .text, contentHash: "hash_\(id ?? 0)",
            text: text, assetPath: nil, summary: nil,
            sourceApp: source, pinned: false, capturedAt: .now,
            lastUsedAt: nil, title: nil, isFavorite: false, tags: nil
        )
    }
}
