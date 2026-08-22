import Foundation
import XCTest
@testable import IndexApp

@MainActor
final class ConfigSetterTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        // 重置到默认值，避免测试间互相污染
        let s = AppSettings.shared
        s.capture = .defaults
        s.library = .defaults
        s.intelligence = .defaults
    }

    func testApplyBoolTogglesAndPersists() {
        let result = ConfigSetter.apply(key: "capture.showMagnifier", value: "false")
        XCTAssertTrue(result.contains("已把"), "应返回成功消息，实际：\(result)")
        XCTAssertEqual(AppSettings.shared.capture.showMagnifier, false)

        // 宽松解析：中文「开」
        let result2 = ConfigSetter.apply(key: "capture.showMagnifier", value: "开")
        XCTAssertTrue(result2.contains("已把"))
        XCTAssertEqual(AppSettings.shared.capture.showMagnifier, true)
    }

    func testApplyInt() {
        let result = ConfigSetter.apply(key: "capture.captureDelay", value: "10")
        XCTAssertTrue(result.contains("已把"), "实际：\(result)")
        XCTAssertEqual(AppSettings.shared.capture.captureDelay, 10)
    }

    func testApplyString() {
        let result = ConfigSetter.apply(key: "annotation.watermarkText", value: "@test")
        XCTAssertTrue(result.contains("已把"), "实际：\(result)")
        XCTAssertEqual(AppSettings.shared.annotationStyle.watermarkText, "@test")
    }

    func testApplyEnterBehavior() {
        let result = ConfigSetter.apply(key: "capture.enterBehavior", value: "finishOnly")
        XCTAssertTrue(result.contains("已把"), "实际：\(result)")
        XCTAssertEqual(AppSettings.shared.capture.enterBehavior, .finishOnly)
    }

    func testInvalidValueReportsError() {
        let result = ConfigSetter.apply(key: "capture.showMagnifier", value: "maybe")
        XCTAssertTrue(result.contains("不是布尔值"), "实际：\(result)")

        let result2 = ConfigSetter.apply(key: "capture.captureDelay", value: "abc")
        XCTAssertTrue(result2.contains("不是数字"), "实际：\(result2)")
    }

    func testUnknownKeyListsAvailable() {
        let result = ConfigSetter.apply(key: "no.such.key", value: "x")
        XCTAssertTrue(result.contains("未知配置项"), "实际：\(result)")
        XCTAssertTrue(result.contains("capture.copyToClipboard"), "应列出可用项")
    }

    func testAvailableKeysIncludesCoreItems() {
        let keys = ConfigSetter.availableKeys
        XCTAssertTrue(keys.contains("capture.copyToClipboard"))
        XCTAssertTrue(keys.contains("capture.captureDelay"))
        XCTAssertTrue(keys.contains("capture.enterBehavior"))
        XCTAssertTrue(keys.contains("intelligence.runOCR"))
    }
}
