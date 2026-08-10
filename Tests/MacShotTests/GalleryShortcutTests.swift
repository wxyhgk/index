import XCTest
import AppKit
@testable import MacShot

/// 图库快捷键守卫的回归测试。
/// 防止 `flags == .command` 的精确相等在 CapsLock/Function 带位时误判为 false。
final class GalleryShortcutTests: XCTestCase {

    func testCommandOnly() {
        let k = GalleryKeyboard.shared
        XCTAssertTrue(k.isCommandOnly(.command), "纯 ⌘ 应命中")
    }

    func testCommandWithCapsLockStillMatches() {
        let k = GalleryKeyboard.shared
        XCTAssertTrue(k.isCommandOnly([.command, .capsLock]), "⌘+CapsLock 应仍命中（忽略）")
        XCTAssertTrue(k.isCommandOnly([.command, .function]), "⌘+Function 应仍命中（忽略）")
        XCTAssertTrue(k.isCommandOnly([.command, .capsLock, .function]), "⌘+CapsLock+Function 仍命中")
    }

    func testCommandWithOtherModifiersDoesNotMatch() {
        let k = GalleryKeyboard.shared
        XCTAssertFalse(k.isCommandOnly([.command, .shift]), "⌘+Shift 不应命中")
        XCTAssertFalse(k.isCommandOnly([.command, .option]), "⌘+Option 不应命中")
        XCTAssertFalse(k.isCommandOnly([.command, .control]), "⌘+Control 不应命中")
        XCTAssertFalse(k.isCommandOnly([.command, .shift, .capsLock]), "⌘+Shift 即便带 CapsLock 也不命中")
    }

    func testNonCommandDoesNotMatch() {
        let k = GalleryKeyboard.shared
        XCTAssertFalse(k.isCommandOnly([]), "无修饰不应命中")
        XCTAssertFalse(k.isCommandOnly(.shift), "Shift 不应命中")
        XCTAssertFalse(k.isCommandOnly(.capsLock), "仅 CapsLock 不应命中")
        XCTAssertFalse(k.isCommandOnly([.command, .capsLock, .shift]), "⌘+CapsLock+Shift 不命中")
    }
}
