import AppKit
import IndexSearchCore

/// 跟随其他 App 光标的非激活结果面板。它不取得键盘焦点，也不改变当前输入法。
@MainActor
final class ContextSearchPanelController: NSWindowController {
    private static let panelWidth: CGFloat = 440
    private static let headerHeight: CGFloat = 34
    private static let rowHeight: CGFloat = 52
    private static let maximumRows = 5

    private let header = NSTextField(labelWithString: "Index")
    private let rows = (0..<maximumRows).map { _ in ContextSearchResultRow() }
    private var activeQuery = ""

    init() {
        let height = Self.headerHeight + Self.rowHeight * CGFloat(Self.maximumRows)
        let panel = ContextSearchPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .popUpMenu
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .transient,
            .ignoresCycle,
            .auxiliary,
            .canJoinAllApplications,
        ]
        panel.animationBehavior = .none

        let content = NSView(frame: panel.contentRect(forFrameRect: panel.frame))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.97).cgColor
        content.layer?.cornerRadius = 11
        content.layer?.borderWidth = 1
        content.layer?.borderColor = NSColor.separatorColor.cgColor
        content.layer?.masksToBounds = true
        panel.contentView = content

        super.init(window: panel)

        header.font = .systemFont(ofSize: 12.5, weight: .semibold)
        header.textColor = .secondaryLabelColor
        header.lineBreakMode = .byTruncatingTail
        content.addSubview(header)
        for row in rows {
            row.onOpen = { [weak self] in self?.openActiveQuery() }
            content.addSubview(row)
        }
        layout(in: content.bounds)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(results: [IndexSearchResult], query: String, caretFrame: NSRect) {
        guard let window else { return }
        activeQuery = query
        header.stringValue = "Index · \(query)"
        for (index, row) in rows.enumerated() {
            if index < results.count {
                row.update(result: results[index])
                row.isHidden = false
            } else {
                row.clear()
                row.isHidden = true
            }
        }
        position(window, near: caretFrame)
        window.orderFrontRegardless()
    }

    func hide() {
        window?.orderOut(nil)
    }

    private func layout(in bounds: NSRect) {
        header.frame = NSRect(
            x: 13,
            y: bounds.height - Self.headerHeight,
            width: bounds.width - 26,
            height: Self.headerHeight
        )
        for (index, row) in rows.enumerated() {
            row.frame = NSRect(
                x: 0,
                y: bounds.height - Self.headerHeight - Self.rowHeight * CGFloat(index + 1),
                width: bounds.width,
                height: Self.rowHeight
            )
        }
    }

    private func position(_ window: NSWindow, near caret: NSRect) {
        let screen = NSScreen.screens.first { $0.frame.intersects(caret) }
            ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        var origin = NSPoint(x: caret.minX, y: caret.minY - window.frame.height - 7)
        if origin.y < visible.minY {
            origin.y = caret.maxY + 7
        }
        origin.x = min(max(origin.x, visible.minX + 6), visible.maxX - window.frame.width - 6)
        origin.y = min(max(origin.y, visible.minY + 6), visible.maxY - window.frame.height - 6)
        window.setFrameOrigin(origin)
    }

    private func openActiveQuery() {
        guard !activeQuery.isEmpty else { return }
        var components = URLComponents()
        components.scheme = "index"
        components.host = "gallery"
        components.queryItems = [URLQueryItem(name: "query", value: activeQuery)]
        guard let url = components.url else { return }
        NSWorkspace.shared.open(url)
        hide()
    }
}

private final class ContextSearchPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class ContextSearchResultRow: NSView {
    private let symbol = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let snippet = NSTextField(labelWithString: "")
    private var tracking: NSTrackingArea?
    var onOpen: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        symbol.imageScaling = .scaleProportionallyDown
        symbol.contentTintColor = .secondaryLabelColor
        title.font = .systemFont(ofSize: 12.5, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        snippet.font = .systemFont(ofSize: 11)
        snippet.textColor = .secondaryLabelColor
        snippet.lineBreakMode = .byTruncatingTail
        [symbol, title, snippet].forEach(addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        symbol.frame = NSRect(x: 13, y: 15, width: 21, height: 21)
        title.frame = NSRect(x: 43, y: 27, width: bounds.width - 56, height: 17)
        snippet.frame = NSRect(x: 43, y: 9, width: bounds.width - 56, height: 16)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = NSColor.selectedContentBackgroundColor.withAlphaComponent(0.12).cgColor
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    override func mouseDown(with event: NSEvent) {
        onOpen?()
    }

    func update(result: IndexSearchResult) {
        title.stringValue = result.title
        snippet.stringValue = result.snippet
        symbol.image = NSImage(
            systemSymbolName: symbolName(for: result.kind),
            accessibilityDescription: result.kind.displayName
        )
        setAccessibilityLabel("\(result.kind.displayName)：\(result.title)，\(result.snippet)")
    }

    func clear() {
        title.stringValue = ""
        snippet.stringValue = ""
        symbol.image = nil
    }

    private func symbolName(for kind: IndexSearchResult.Kind) -> String {
        switch kind {
        case .screenshot: return "photo"
        case .markdown: return "text.document"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .clipboardText: return "clipboard"
        case .clipboardImage: return "photo.on.rectangle"
        case .clipboardFile: return "doc.on.clipboard"
        }
    }
}
