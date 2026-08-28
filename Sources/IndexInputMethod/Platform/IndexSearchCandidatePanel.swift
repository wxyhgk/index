import AppKit
import IndexSearchCore

// 输入法 target 的 AppKit 窗口副作用统一收在 Platform/。

final class IndexSearchCandidatePanelController: NSWindowController {
    private static let panelWidth: CGFloat = 520
    private static let headerHeight: CGFloat = 38
    private static let rowHeight: CGFloat = 64
    private static let maximumRows = 6

    private let header = NSTextField(labelWithString: "Index")
    private let rows = (0..<maximumRows).map { _ in IndexSearchCandidateRowView() }
    private var activeQuery = ""

    init() {
        let height = Self.headerHeight + Self.rowHeight * CGFloat(Self.maximumRows)
        let panel = IndexSearchPanel(
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
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.animationBehavior = .none

        let content = IndexSearchPanelContentView(frame: panel.contentRect(forFrameRect: panel.frame))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.98).cgColor
        content.layer?.cornerRadius = 12
        content.layer?.borderWidth = 1
        content.layer?.borderColor = NSColor.separatorColor.cgColor
        content.layer?.masksToBounds = true
        panel.contentView = content

        super.init(window: panel)

        header.font = .systemFont(ofSize: 13, weight: .semibold)
        header.textColor = .secondaryLabelColor
        header.lineBreakMode = .byTruncatingTail
        content.addSubview(header)
        for row in rows {
            row.onOpen = { [weak self] in self?.openActiveQuery() }
            content.addSubview(row)
        }
        layoutRows(in: content.bounds)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(
        results: [IndexSearchResult],
        query: String,
        navigationQuery: String? = nil,
        caretFrame: NSRect
    ) {
        guard let window else { return }
        activeQuery = navigationQuery ?? query
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
        position(window: window, near: caretFrame)
        window.orderFrontRegardless()
    }

    func hide() {
        window?.orderOut(nil)
    }

    private func layoutRows(in bounds: NSRect) {
        header.frame = NSRect(
            x: 14,
            y: bounds.height - Self.headerHeight,
            width: bounds.width - 28,
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

    private func position(window: NSWindow, near caret: NSRect) {
        let screen = NSScreen.screens.first { $0.visibleFrame.intersects(caret) }
            ?? NSScreen.screens.first { $0.visibleFrame.contains(caret.origin) }
            ?? NSScreen.main
        guard let visibleFrame = screen?.visibleFrame else { return }

        var origin = NSPoint(
            x: caret.minX,
            y: caret.minY - window.frame.height - 8
        )
        if origin.y < visibleFrame.minY {
            origin.y = caret.maxY + 8
        }
        origin.x = min(max(origin.x, visibleFrame.minX + 8), visibleFrame.maxX - window.frame.width - 8)
        origin.y = min(max(origin.y, visibleFrame.minY + 8), visibleFrame.maxY - window.frame.height - 8)
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

private final class IndexSearchPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class IndexSearchPanelContentView: NSView {
    override var isFlipped: Bool { false }
}

private final class IndexSearchCandidateRowView: NSView {
    private let thumbnail = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let snippetLabel = NSTextField(labelWithString: "")
    private let kindLabel = NSTextField(labelWithString: "")
    private var tracking: NSTrackingArea?
    var onOpen: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        thumbnail.imageScaling = .scaleProportionallyUpOrDown
        thumbnail.wantsLayer = true
        thumbnail.layer?.cornerRadius = 6
        thumbnail.layer?.masksToBounds = true
        thumbnail.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.font = .systemFont(ofSize: 10.5)
        subtitleLabel.textColor = .tertiaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingTail
        snippetLabel.font = .systemFont(ofSize: 11.5)
        snippetLabel.textColor = .secondaryLabelColor
        snippetLabel.lineBreakMode = .byTruncatingTail
        kindLabel.font = .systemFont(ofSize: 10, weight: .medium)
        kindLabel.textColor = .secondaryLabelColor
        kindLabel.alignment = .right

        [thumbnail, titleLabel, subtitleLabel, snippetLabel, kindLabel].forEach(addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        thumbnail.frame = NSRect(x: 12, y: 7, width: 50, height: 50)
        kindLabel.frame = NSRect(x: bounds.width - 92, y: 39, width: 78, height: 16)
        titleLabel.frame = NSRect(x: 72, y: 38, width: bounds.width - 174, height: 18)
        snippetLabel.frame = NSRect(x: 72, y: 20, width: bounds.width - 86, height: 17)
        subtitleLabel.frame = NSRect(x: 72, y: 5, width: bounds.width - 86, height: 15)
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

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func update(result: IndexSearchResult) {
        titleLabel.stringValue = result.title
        subtitleLabel.stringValue = result.subtitle
        snippetLabel.stringValue = result.snippet
        kindLabel.stringValue = result.kind.displayName
        if let url = result.assetURL, FileManager.default.isReadableFile(atPath: url.path) {
            thumbnail.image = NSImage(contentsOf: url)
        } else {
            thumbnail.image = NSImage(
                systemSymbolName: symbolName(for: result.kind),
                accessibilityDescription: result.kind.displayName
            )
        }
        toolTip = "点击在 Index 中打开“\(result.title)”的检索结果"
        setAccessibilityLabel("\(result.kind.displayName)：\(result.title)，\(result.snippet)")
    }

    func clear() {
        thumbnail.image = nil
        titleLabel.stringValue = ""
        subtitleLabel.stringValue = ""
        snippetLabel.stringValue = ""
        kindLabel.stringValue = ""
        toolTip = nil
    }

    private func symbolName(for kind: IndexSearchResult.Kind) -> String {
        switch kind {
        case .screenshot: return "photo"
        case .markdown: return "text.document"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .clipboardText: return "doc.on.clipboard"
        case .clipboardImage: return "photo.on.rectangle"
        case .clipboardFile: return "doc"
        }
    }
}
