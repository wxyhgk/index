import AppKit
import IndexSearchCore

/// Fixed, reusable candidate strip for the AOSP decoder. No SwiftUI tree is rebuilt per key.
final class PinyinCandidatePanelController: NSWindowController {
    private static let initialWidth: CGFloat = 680
    private static let maximumWidth: CGFloat = 1_180
    private static let height: CGFloat = 52
    private let items = (0..<9).map { _ in PinyinCandidateItemView() }
    private let previousButton = PinyinCandidatePageButton(
        symbolName: "chevron.left",
        accessibilityTitle: "上一页候选"
    )
    private let nextButton = PinyinCandidatePageButton(
        symbolName: "chevron.right",
        accessibilityTitle: "下一页候选"
    )
    private let pageLabel = NSTextField(labelWithString: "")
    private var currentPageStartIndex = 0
    var onSelect: ((Int) -> Void)?
    var onPreviousPage: (() -> Void)?
    var onNextPage: (() -> Void)?

    init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.initialWidth, height: Self.height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .popUpMenu
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.animationBehavior = .none

        let content = NSView(frame: panel.contentRect(forFrameRect: panel.frame))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.98).cgColor
        content.layer?.cornerRadius = 10
        content.layer?.borderWidth = 1
        content.layer?.borderColor = NSColor.separatorColor.cgColor
        content.layer?.masksToBounds = true
        panel.contentView = content
        super.init(window: panel)

        for (index, item) in items.enumerated() {
            item.onClick = { [weak self] in
                guard let self else { return }
                self.onSelect?(self.currentPageStartIndex + index)
            }
            content.addSubview(item)
        }
        previousButton.onClick = { [weak self] in self?.onPreviousPage?() }
        nextButton.onClick = { [weak self] in self?.onNextPage?() }
        pageLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        pageLabel.textColor = .secondaryLabelColor
        pageLabel.alignment = .center
        content.addSubview(previousButton)
        content.addSubview(pageLabel)
        content.addSubview(nextButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(candidates: [String], pagination: CandidatePagination, caretFrame: NSRect) {
        guard let window else { return }
        currentPageStartIndex = pagination.visibleRange.lowerBound
        let candidateIndices = Array(pagination.visibleRange).filter { $0 < candidates.count }
        let showsPaging = pagination.pageCount > 1
        let controlsWidth: CGFloat = showsPaging ? 94 : 0
        let leftInset: CGFloat = 7
        let gap: CGFloat = 4
        let preferredWidths = candidateIndices.enumerated().map { localIndex, candidateIndex in
            PinyinCandidateItemView.preferredWidth(
                number: localIndex + 1,
                candidate: candidates[candidateIndex]
            )
        }
        let totalGaps = gap * CGFloat(max(0, candidateIndices.count - 1))
        let desiredWidth = leftInset * 2 + preferredWidths.reduce(0, +) + totalGaps + controlsWidth
        let visibleFrame = screenFrame(containing: caretFrame)
        let maximumWidth = min(Self.maximumWidth, max(360, visibleFrame.width - 16))
        let panelWidth = min(maximumWidth, max(360, desiredWidth))
        window.setContentSize(NSSize(width: panelWidth, height: Self.height))

        let itemBudget = panelWidth - leftInset * 2 - controlsWidth - totalGaps
        let itemWidths = fittedWidths(preferredWidths, budget: itemBudget)
        var x = leftInset
        for (index, item) in items.enumerated() {
            let candidateIndex = currentPageStartIndex + index
            guard pagination.visibleRange.contains(candidateIndex), candidateIndex < candidates.count else {
                item.isHidden = true
                continue
            }
            let itemWidth = itemWidths[index]
            item.frame = NSRect(
                x: x,
                y: 7,
                width: itemWidth,
                height: 38
            )
            item.update(
                number: index + 1,
                candidate: candidates[candidateIndex],
                selected: candidateIndex == pagination.selectedIndex
            )
            item.isHidden = false
            x += itemWidth + gap
        }

        previousButton.isHidden = !showsPaging
        nextButton.isHidden = !showsPaging
        pageLabel.isHidden = !showsPaging
        if showsPaging {
            let controlsX = panelWidth - controlsWidth + 5
            previousButton.frame = NSRect(x: controlsX, y: 12, width: 24, height: 28)
            pageLabel.frame = NSRect(x: controlsX + 26, y: 18, width: 34, height: 16)
            nextButton.frame = NSRect(x: controlsX + 61, y: 12, width: 24, height: 28)
            pageLabel.stringValue = "\(pagination.pageIndex + 1)/\(pagination.pageCount)"
            previousButton.update(enabled: pagination.pageIndex > 0)
            nextButton.update(enabled: pagination.pageIndex + 1 < pagination.pageCount)
        }
        position(window, near: caretFrame)
        window.orderFrontRegardless()
    }

    private func fittedWidths(_ preferred: [CGFloat], budget: CGFloat) -> [CGFloat] {
        guard !preferred.isEmpty else { return [] }
        let minimumWidth: CGFloat = 70
        let preferredTotal = preferred.reduce(0, +)
        guard preferredTotal > budget else { return preferred }
        if minimumWidth * CGFloat(preferred.count) > budget {
            return Array(
                repeating: max(40, budget / CGFloat(preferred.count)),
                count: preferred.count
            )
        }

        let flexibleTotal = preferred.reduce(0) { $0 + max(0, $1 - minimumWidth) }
        guard flexibleTotal > 0 else {
            return Array(repeating: max(44, budget / CGFloat(preferred.count)), count: preferred.count)
        }
        let overflow = preferredTotal - budget
        return preferred.map { width in
            let flexible = max(0, width - minimumWidth)
            return max(minimumWidth, width - overflow * flexible / flexibleTotal)
        }
    }

    private func screenFrame(containing caret: NSRect) -> NSRect {
        let screen = NSScreen.screens.first { $0.frame.intersects(caret) }
            ?? NSScreen.main
        return screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: Self.initialWidth, height: 800)
    }

    func hide() { window?.orderOut(nil) }

    /// When the strip is below the caret, content results should anchor below
    /// the strip instead of occupying the same rectangle.
    func searchAnchorFrame(fallback caret: NSRect) -> NSRect {
        guard let window, window.isVisible, window.frame.maxY <= caret.minY + 1 else {
            return caret
        }
        return NSRect(x: caret.minX, y: window.frame.minY, width: 1, height: 1)
    }

    private func position(_ window: NSWindow, near caret: NSRect) {
        let screen = NSScreen.screens.first { $0.frame.intersects(caret) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        var origin = NSPoint(x: caret.minX, y: caret.minY - window.frame.height - 6)
        if origin.y < visible.minY { origin.y = caret.maxY + 6 }
        origin.x = min(max(origin.x, visible.minX + 6), visible.maxX - window.frame.width - 6)
        origin.y = min(max(origin.y, visible.minY + 6), visible.maxY - window.frame.height - 6)
        window.setFrameOrigin(origin)
    }
}

private final class PinyinCandidateItemView: NSView {
    private let label = NSTextField(labelWithString: "")
    var onClick: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 6
        label.alignment = .left
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        label.frame = bounds.insetBy(dx: 10, dy: 8)
    }

    override func mouseDown(with event: NSEvent) { onClick?() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    static func preferredWidth(number: Int, candidate: String) -> CGFloat {
        let numberWidth = ("\(number)" as NSString).size(
            withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium)]
        ).width
        let candidateWidth = (candidate as NSString).size(
            withAttributes: [.font: NSFont.systemFont(ofSize: 16)]
        ).width
        return min(220, max(70, numberWidth + candidateWidth + 30))
    }

    func update(number: Int, candidate: String, selected: Bool) {
        let numberColor = selected
            ? NSColor.selectedMenuItemTextColor.withAlphaComponent(0.72)
            : NSColor.tertiaryLabelColor
        let candidateColor = selected ? NSColor.selectedMenuItemTextColor : NSColor.labelColor
        let attributed = NSMutableAttributedString(
            string: "\(number)  ",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: numberColor,
            ]
        )
        attributed.append(NSAttributedString(
            string: candidate,
            attributes: [
                .font: NSFont.systemFont(ofSize: 16),
                .foregroundColor: candidateColor,
            ]
        ))
        label.attributedStringValue = attributed
        layer?.backgroundColor = selected
            ? NSColor.selectedContentBackgroundColor.cgColor
            : NSColor.clear.cgColor
        toolTip = candidate
        setAccessibilityLabel("候选 \(number)：\(candidate)")
    }
}

private final class PinyinCandidatePageButton: NSView {
    private let imageView: NSImageView
    private let accessibilityTitle: String
    private var isEnabled = true
    var onClick: (() -> Void)?

    init(symbolName: String, accessibilityTitle: String) {
        self.accessibilityTitle = accessibilityTitle
        imageView = NSImageView(image: NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: nil
        ) ?? NSImage())
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        imageView.imageScaling = .scaleProportionallyDown
        addSubview(imageView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        imageView.frame = bounds.insetBy(dx: 6, dy: 7)
    }

    override func mouseDown(with event: NSEvent) {
        if isEnabled { onClick?() }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func update(enabled: Bool) {
        isEnabled = enabled
        imageView.contentTintColor = enabled ? .labelColor : .disabledControlTextColor
        setAccessibilityLabel(enabled ? accessibilityTitle : "\(accessibilityTitle)，没有更多候选")
    }
}
