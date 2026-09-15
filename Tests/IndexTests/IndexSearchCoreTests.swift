import QingjianPinyinIME
import Foundation
import GRDB
import XCTest
@testable import IndexSearchCore

final class IndexSearchCoreTests: XCTestCase {
    func testQueryBufferBuildsMixedLanguageQueryWithoutShortcut() {
        var buffer = InputQueryBuffer()

        XCTAssertEqual(buffer.consume(.text("o")), nil)
        XCTAssertEqual(buffer.consume(.text("pencode")), "opencode")
        XCTAssertEqual(buffer.consume(.text(" ")), "opencode")
        XCTAssertEqual(buffer.consume(.text("安装")), "opencode 安装")
        XCTAssertEqual(buffer.consume(.deleteBackward), "opencode 安")
        XCTAssertNil(buffer.consume(.boundary))
        XCTAssertEqual(buffer.text, "")
    }

    func testQueryBufferStartsFreshAfterSentenceBoundary() {
        var buffer = InputQueryBuffer()

        _ = buffer.consume(.text("previous query。"))
        XCTAssertNil(buffer.query)
        XCTAssertEqual(buffer.consume(.text("新查询")), "新查询")
    }

    func testContextQueryExtractorUsesCommittedChineseTextAfterExistingIME() {
        XCTAssertEqual(
            ContextQueryExtractor.query(fromTextBeforeCaret: "前面的句子。opencode 安装"),
            "opencode 安装"
        )
        XCTAssertEqual(
            ContextQueryExtractor.query(fromTextBeforeCaret: "我想搜索截图"),
            "我想搜索截图"
        )
    }

    func testContextQueryExtractorRejectsShortOrBoundaryOnlyText() {
        XCTAssertNil(ContextQueryExtractor.query(fromTextBeforeCaret: "中"))
        XCTAssertNil(ContextQueryExtractor.query(fromTextBeforeCaret: "ab"))
        XCTAssertNil(ContextQueryExtractor.query(fromTextBeforeCaret: "完成。"))
    }

    func testInputSearchPlannerKeepsEnglishAndChineseInterpretationsIndependent() {
        XCTAssertEqual(
            InputSearchQueryPlanner.queries(
                composition: "opencode",
                pinyinCandidates: ["哦喷错的"]
            ),
            ["opencode", "哦喷错的"]
        )
        XCTAssertEqual(
            InputSearchQueryPlanner.queries(
                composition: "jietu",
                pinyinCandidates: ["截图", "街图"]
            ),
            ["jietu", "截图"]
        )
        XCTAssertTrue(
            InputSearchQueryPlanner.queries(
                composition: "op",
                pinyinCandidates: ["哦"]
            ).isEmpty
        )
    }

    func testShiftTapTogglesOnlyAfterCleanPressAndRelease() {
        var state = ShiftLanguageSwitchState()

        XCTAssertFalse(state.flagsChanged(shiftIsDown: true, hasBlockingModifiers: false))
        XCTAssertTrue(state.flagsChanged(shiftIsDown: false, hasBlockingModifiers: false))
        XCTAssertFalse(state.flagsChanged(shiftIsDown: false, hasBlockingModifiers: false))
    }

    func testShiftWithCharacterDoesNotToggleLanguage() {
        var state = ShiftLanguageSwitchState()

        XCTAssertFalse(state.flagsChanged(shiftIsDown: true, hasBlockingModifiers: false))
        state.noteKeyDown()
        XCTAssertFalse(state.flagsChanged(shiftIsDown: false, hasBlockingModifiers: false))
    }

    func testShiftWithCommandDoesNotToggleLanguage() {
        var state = ShiftLanguageSwitchState()

        XCTAssertFalse(state.flagsChanged(shiftIsDown: true, hasBlockingModifiers: true))
        XCTAssertFalse(state.flagsChanged(shiftIsDown: false, hasBlockingModifiers: true))
    }

    func testSecondShiftCancelsTapGesture() {
        var state = ShiftLanguageSwitchState()

        XCTAssertFalse(state.flagsChanged(shiftIsDown: true, hasBlockingModifiers: false))
        XCTAssertFalse(state.flagsChanged(shiftIsDown: true, hasBlockingModifiers: false))
        XCTAssertFalse(state.flagsChanged(shiftIsDown: false, hasBlockingModifiers: false))
    }

    func testLanguageModeTogglesBothDirections() {
        XCTAssertEqual(InputLanguageMode.chinese.toggled, .english)
        XCTAssertEqual(InputLanguageMode.english.toggled, .chinese)
    }

    func testCandidatePaginationMapsNumbersToCurrentPage() {
        var pagination = CandidatePagination(pageSize: 9)
        pagination.reset(itemCount: 23)

        XCTAssertEqual(pagination.pageCount, 3)
        XCTAssertEqual(pagination.visibleRange, 0..<9)
        XCTAssertEqual(pagination.absoluteIndex(forNumber: 9), 8)

        pagination.movePage(by: 1)
        XCTAssertEqual(pagination.pageIndex, 1)
        XCTAssertEqual(pagination.visibleRange, 9..<18)
        XCTAssertEqual(pagination.absoluteIndex(forNumber: 1), 9)
        XCTAssertEqual(pagination.absoluteIndex(forNumber: 9), 17)

        pagination.movePage(by: 1)
        XCTAssertEqual(pagination.visibleRange, 18..<23)
        XCTAssertEqual(pagination.absoluteIndex(forNumber: 5), 22)
        XCTAssertNil(pagination.absoluteIndex(forNumber: 6))
    }

    func testCandidatePaginationFollowsArrowSelectionAcrossPages() {
        var pagination = CandidatePagination(pageSize: 9)
        pagination.reset(itemCount: 20)
        pagination.moveSelection(by: 9)

        XCTAssertEqual(pagination.selectedIndex, 9)
        XCTAssertEqual(pagination.pageIndex, 1)

        pagination.moveSelection(by: 50)
        XCTAssertEqual(pagination.selectedIndex, 19)
        XCTAssertEqual(pagination.pageIndex, 2)

        pagination.reset(itemCount: 3)
        XCTAssertEqual(pagination.selectedIndex, 0)
        XCTAssertEqual(pagination.pageCount, 1)
    }

    func testRepositoryMixesScreenshotAndClipboardResults() throws {
        let database = try makeDatabase()
        let root = URL(fileURLWithPath: "/tmp/index-search-core-tests", isDirectory: true)
        let repository = IndexSearchRepository(database: database, dataRoot: root)

        let results = try repository.search("opencode 安装", limit: 6)

        XCTAssertEqual(Set(results.map(\.kind)), [.screenshot, .clipboardText])
        XCTAssertEqual(results.first?.title, "OpenCode 安装说明")
        XCTAssertTrue(results.first?.snippet.lowercased().contains("opencode") == true)
        XCTAssertEqual(
            results.first(where: { $0.kind == .screenshot })?.assetURL,
            root.appendingPathComponent("thumbnails/shot-a.jpg")
        )
    }

    func testRepositoryEscapesLikeWildcards() throws {
        let database = try makeDatabase()
        let root = URL(fileURLWithPath: "/tmp/index-search-core-tests", isDirectory: true)
        let repository = IndexSearchRepository(database: database, dataRoot: root)

        XCTAssertTrue(try repository.search("100%", limit: 6).isEmpty)
    }

    func testInputMethodUsesIndexAppIcon() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let plistURL = repositoryRoot.appendingPathComponent("Resources/IndexInputMethod-Info.plist")
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: Data(contentsOf: plistURL), format: nil)
                as? [String: Any]
        )
        XCTAssertEqual(plist["tsInputMethodIconFileKey"] as? String, "Index.icns")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: repositoryRoot.appendingPathComponent("Resources/Index.icns").path
        ))
    }

    func testQingjianPinyinDecoderReturnsChineseCandidates() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let dict = repositoryRoot
            .appendingPathComponent("Resources/IndexInputMethod/dict.qj")
        defer { qingjian_pinyin_close() }
        let opened = dict.path.withCString { qingjian_pinyin_open($0) }
        XCTAssertTrue(opened)

        // 逐键输入 "nihao"
        for char in "nihao" {
            qingjian_pinyin_push(UInt16(char.asciiValue ?? 0))
        }
        let count = qingjian_pinyin_query()
        XCTAssertGreaterThan(count, 0)

        let candidates: [String] = (0..<min(Int(count), 12)).compactMap { index in
            var utf16 = [UInt16](repeating: 0, count: 64)
            let length = utf16.withUnsafeMutableBufferPointer { buffer in
                qingjian_pinyin_copy_candidate(index, buffer.baseAddress, buffer.count)
            }
            return length > 0 ? String(decoding: utf16.prefix(Int(length)), as: UTF16.self) : nil
        }
        XCTAssertTrue(candidates.contains("你好"), "nihao candidates: \(candidates)")

        // 清空后输入 "shi"，常见单音节应有多个候选
        qingjian_pinyin_clear()
        for char in "shi" {
            qingjian_pinyin_push(UInt16(char.asciiValue ?? 0))
        }
        let expandedCount = qingjian_pinyin_query()
        XCTAssertGreaterThan(expandedCount, 9, "常见单音节应能提供第二页候选")
    }

    private func makeDatabase() throws -> DatabaseQueue {
        let database = try DatabaseQueue()
        try database.write { db in
            try db.create(table: "shot") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("sha256", .text).notNull()
                table.column("capturedAt", .datetime).notNull()
                table.column("customTitle", .text)
                table.column("windowTitle", .text)
                table.column("appName", .text)
                table.column("sourceURL", .text)
                table.column("ocrText", .text)
                table.column("contentKind", .text).notNull().defaults(to: "image")
            }
            try db.create(table: "clipboardHistory") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("kind", .text).notNull()
                table.column("title", .text)
                table.column("summary", .text)
                table.column("text", .text)
                table.column("assetPath", .text)
                table.column("sourceApp", .text)
                table.column("pinned", .boolean).notNull().defaults(to: false)
                table.column("isFavorite", .boolean).notNull().defaults(to: false)
                table.column("capturedAt", .datetime).notNull()
            }

            try db.execute(sql: """
                INSERT INTO shot
                    (sha256, capturedAt, customTitle, windowTitle, appName, sourceURL, ocrText, contentKind)
                VALUES
                    ('shot-a', :now, 'OpenCode 安装说明', '终端', 'Terminal', NULL,
                     'opencode 安装：执行 brew install opencode', 'image'),
                    ('shot-b', :older, '别的截图', '浏览器', 'Safari', NULL,
                     '完全无关的内容', 'image')
                """, arguments: [
                    "now": Date(timeIntervalSince1970: 2_000),
                    "older": Date(timeIntervalSince1970: 1_000),
                ])
            try db.execute(sql: """
                INSERT INTO clipboardHistory
                    (kind, title, summary, text, assetPath, sourceApp, pinned, isFavorite, capturedAt)
                VALUES
                    ('text', NULL, '安装命令', 'opencode 安装命令', NULL, 'Terminal', 0, 0, :now)
                """, arguments: ["now": Date(timeIntervalSince1970: 1_500)])
        }
        return database
    }
}
