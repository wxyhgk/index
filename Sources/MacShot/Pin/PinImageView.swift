import AppKit

/// 钉图的内容视图。只做事件翻译和调用渲染 —— 布局在 PinToolbarLayout，绘制在 PinToolbarRenderer。
final class PinImageView: NSView {

    var onScrollZoom: ((CGFloat) -> Void)?
    var onOpacityStep: ((CGFloat) -> Void)?
    var onAction: ((PinAction) -> Void)?

    private let cgImage: CGImage
    private var isHovering = false
    private var hoveredAction: PinAction?

    private var toolbarButtons: [PinToolbarButton] {
        isHovering ? PinToolbarLayout.buttons(in: bounds) : []
    }

    init(image: CGImage) {
        self.cgImage = image
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.25).cgColor
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    /// 钉图窗口经常不是 key，没有这个的话第一次点击会被吞掉。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// 自己接管拖动，AppKit 不要插手 —— 否则点悬停工具条会被当成拖窗口。
    override var mouseDownCanMoveWindow: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved],
            owner: self,
            userInfo: nil
        ))
    }

    // MARK: - 事件

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        hoveredAction = nil
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let hit = toolbarButtons.first { $0.frame.contains(point) }?.action
        if hit != hoveredAction {
            hoveredAction = hit
            needsDisplay = true
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        if let hit = toolbarButtons.first(where: { $0.frame.contains(point) }) {
            onAction?(hit.action)
            return
        }

        if event.clickCount == 2 {
            onAction?(.gallery)
            return
        }

        window?.performDrag(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            onOpacityStep?(event.scrollingDeltaY > 0 ? 0.05 : -0.05)
        } else {
            onScrollZoom?(event.scrollingDeltaY)
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53:                                             // ESC
            onAction?(.close)
        case 8 where event.modifierFlags.contains(.command):  // ⌘C
            onAction?(.copy)
        default:
            super.keyDown(with: event)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        for action in PinAction.allCases {
            if action == .close { menu.addItem(.separator()) }
            let item = NSMenuItem(
                title: action.title,
                action: #selector(menuAction(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = action
            menu.addItem(item)
        }
        return menu
    }

    @objc private func menuAction(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? PinAction else { return }
        onAction?(action)
    }

    // MARK: - 绘制

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.interpolationQuality = .high
        ctx.draw(cgImage, in: bounds)

        PinToolbarRenderer.draw(toolbarButtons, hovered: hoveredAction)
    }
}
