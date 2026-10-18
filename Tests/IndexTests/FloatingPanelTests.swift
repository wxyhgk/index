import XCTest
import AppKit
@testable import IndexApp

/// `PanelSpec` 的行为快照。
///
/// 这些窗口属性以前散在四个面板的 init 里，没有测试；收敛到 `FloatingPanel`
/// 之后用一组断言把每个预设钉住，避免以后改预设时悄悄改变某个面板的窗口语义。
@MainActor
final class FloatingPanelTests: XCTestCase {

    private func makePanel(_ spec: PanelSpec) -> FloatingPanel {
        FloatingPanel(spec: spec, contentViewController: NSViewController())
    }

    func testSearchSpec() {
        let panel = makePanel(.search(size: CGSize(width: 640, height: 420)))
        XCTAssertEqual(panel.styleMask, .borderless)
        XCTAssertEqual(panel.level, .floating)
        XCTAssertTrue(panel.collectionBehavior.contains(.stationary))
        XCTAssertFalse(panel.isOpaque)
        XCTAssertEqual(panel.backgroundColor, .clear)
        XCTAssertFalse(panel.isMovable)
        XCTAssertTrue(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertFalse(panel.isReleasedWhenClosed)
        XCTAssertFalse(panel.hidesOnDeactivate)
    }

    func testAgentSpec() {
        let panel = makePanel(.agent(size: CGSize(width: 520, height: 640)))
        XCTAssertEqual(panel.title, "Agent")
        XCTAssertTrue(panel.styleMask.contains(.resizable))
        XCTAssertTrue(panel.canBecomeMain)
        XCTAssertTrue(panel.canBecomeKey)
        XCTAssertFalse(panel.becomesKeyOnlyIfNeeded)
        XCTAssertEqual(panel.level, .floating)
    }

    func testClipboardSpec() {
        let panel = makePanel(.clipboard(size: CGSize(width: 1100, height: 320)))
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertTrue(panel.styleMask.contains(.borderless))
        XCTAssertTrue(panel.collectionBehavior.contains(.stationary))
        XCTAssertFalse(panel.isOpaque)
        XCTAssertTrue(panel.isMovable)
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertFalse(panel.becomesKeyOnlyIfNeeded)
    }

    func testQuickNoteSpec() {
        let panel = makePanel(.quickNote(size: CGSize(width: 560, height: 420)))
        XCTAssertTrue(panel.styleMask.contains(.fullSizeContentView))
        XCTAssertTrue(panel.titlebarAppearsTransparent)
        XCTAssertEqual(panel.titleVisibility, .hidden)
        XCTAssertTrue(panel.isMovableByWindowBackground)
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertTrue(panel.canBecomeKey)
        XCTAssertEqual(panel.standardWindowButton(.closeButton)?.isHidden, true)
        XCTAssertEqual(panel.standardWindowButton(.zoomButton)?.isHidden, true)
    }

    func testContentCornerRadiusApplied() throws {
        var spec = PanelSpec.search(size: CGSize(width: 200, height: 200))
        spec.contentCornerRadius = 14
        let panel = makePanel(spec)
        let layer = try XCTUnwrap(panel.contentView?.layer)
        XCTAssertTrue(layer.masksToBounds)
        XCTAssertEqual(layer.cornerRadius, 14)
    }

    /// 基类不能因为子类覆盖而改变焦点语义：预设说不能成为 main，就必须不能。
    func testCanBecomeMainFollowsSpec() {
        var spec = PanelSpec.search(size: CGSize(width: 100, height: 100))
        spec.canBecomeMain = true
        XCTAssertTrue(makePanel(spec).canBecomeMain)

        spec.canBecomeMain = false
        XCTAssertFalse(makePanel(spec).canBecomeMain)
    }
}
