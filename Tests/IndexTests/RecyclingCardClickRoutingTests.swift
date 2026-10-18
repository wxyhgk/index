import AppKit
import GRDB
import SwiftUI
import XCTest
@testable import IndexApp

final class RecyclingCardClickRoutingTests: XCTestCase {
    @MainActor
    func testPlainCardSurfaceKeepsCardSelection() {
        let cell = NSView()
        let surface = NSView()
        cell.addSubview(surface)

        XCTAssertTrue(RecyclingCardClickRouting.shouldHandleCardClick(
            hitView: surface,
            cellView: cell
        ))
    }

    @MainActor
    func testControlDescendantSuppressesCardSelection() {
        let cell = NSView()
        let container = NSView()
        let button = NSButton()
        cell.addSubview(container)
        container.addSubview(button)

        XCTAssertFalse(RecyclingCardClickRouting.shouldHandleCardClick(
            hitView: button,
            cellView: cell
        ))
    }

    @MainActor
    func testTextEditorSuppressesCardSelection() {
        let cell = NSView()
        let textView = NSTextView()
        cell.addSubview(textView)

        XCTAssertFalse(RecyclingCardClickRouting.shouldHandleCardClick(
            hitView: textView,
            cellView: cell
        ))
    }

    func testClipboardCardInteractionUsesOnlyMiddleContentForSelection() {
        let size = NSSize(width: 220, height: 196)

        XCTAssertEqual(
            ClipboardCardInteractionZones.zone(at: NSPoint(x: 100, y: 195), in: size),
            .header
        )
        XCTAssertEqual(
            ClipboardCardInteractionZones.zone(at: NSPoint(x: 100, y: 80), in: size),
            .content
        )
        XCTAssertEqual(
            ClipboardCardInteractionZones.zone(at: NSPoint(x: 100, y: 10), in: size),
            .footer
        )
        XCTAssertFalse(ClipboardCardInteractionZones.selectsCard(
            at: NSPoint(x: 100, y: 175),
            in: size
        ))
        XCTAssertTrue(ClipboardCardInteractionZones.selectsCard(
            at: NSPoint(x: 100, y: 80),
            in: size
        ))
    }

    @MainActor
    func testRenameFieldFocusesAfterLatePanelAttachment() throws {
        let store = try ClipboardHistoryStore(writer: DatabaseQueue())
        var committedTitles: [String] = []
        let item = ClipboardHistoryItem(
            id: 91,
            kind: .text,
            contentHash: "late-title-focus",
            text: "正文",
            assetPath: nil,
            summary: "正文",
            sourceApp: nil,
            pinned: false,
            capturedAt: Date(),
            lastUsedAt: nil,
            title: "旧名称",
            isFavorite: false
        )
        let host = NSHostingView(rootView: ClipboardCardBody(
            item: item,
            store: store,
            isRenaming: true,
            renameText: "旧名称",
            onCommitRename: { committedTitles.append($0) }
        ))
        host.frame = NSRect(
            origin: .zero,
            size: NSSize(
                width: ClipboardCardMetrics.gridWidth,
                height: ClipboardCardMetrics.gridHeight
            )
        )
        host.layoutSubtreeIfNeeded()
        drainMainRunLoop()
        XCTAssertNil(host.window)

        let panel = RenameFocusTestPanel(
            contentRect: host.bounds,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = host
        panel.orderFrontRegardless()
        panel.makeKey()
        host.layoutSubtreeIfNeeded()
        drainMainRunLoop()
        defer { panel.orderOut(nil) }

        guard let field = firstTextField(in: host) else {
            XCTFail("重命名输入框应已经创建")
            return
        }
        XCTAssertNotNil(field.currentEditor())
        XCTAssertTrue(panel.firstResponder === field.currentEditor())

        let editorView = try? XCTUnwrap(field.superview)
        let outsidePoint = [
            NSPoint(x: host.bounds.midX, y: host.bounds.maxY - 12),
            NSPoint(x: host.bounds.midX, y: host.bounds.minY + 12),
        ]
            .map { host.convert($0, to: nil) }
            .first { point in
                guard let editorView else { return true }
                return !editorView.bounds.contains(editorView.convert(point, from: nil))
            }
        guard let outsidePoint else {
            XCTFail("应能找到标题编辑器外部的窗口坐标")
            return
        }
        guard let editorView else {
            XCTFail("标题编辑器应存在")
            return
        }
        XCTAssertTrue(ClipboardCardTitleEditorClickRouting.isOutsideEditor(
            windowPoint: outsidePoint,
            editorView: editorView
        ))
        panel.makeFirstResponder(nil)
        drainMainRunLoop()

        XCTAssertNil(field.currentEditor())
        XCTAssertEqual(committedTitles, ["旧名称"])
    }

    @MainActor
    private func firstTextField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField { return field }
        for child in view.subviews {
            if let field = firstTextField(in: child) { return field }
        }
        return nil
    }

    @MainActor
    private func drainMainRunLoop() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
    }
}

@MainActor
private final class RenameFocusTestPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
