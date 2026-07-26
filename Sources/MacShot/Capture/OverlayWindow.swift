import AppKit

/// 铺在单块显示器上的无边框覆盖窗口。
final class OverlayWindow: NSWindow {

    init(screen: NSScreen) {
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .screenSaver
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        setFrame(screen.frame, display: true)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// 只画矢量装饰的透明层。不参与命中测试 —— 事件穿透回 OverlayView。
final class ChromeView: NSView {

    var render: ((CGContext, CGRect) -> Void)?

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        render?(ctx, bounds)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
