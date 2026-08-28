import AppKit
import IndexSearchCore

/// 中英文切换后的短暂反馈；窗口固定复用，不参与输入焦点。
final class InputLanguageModeIndicatorController: NSWindowController {
    private static let size = NSSize(width: 42, height: 42)
    private let label = NSTextField(labelWithString: "中")
    private var hideWorkItem: DispatchWorkItem?

    init() {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
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

        let content = NSView(frame: NSRect(origin: .zero, size: Self.size))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.96).cgColor
        content.layer?.cornerRadius = 10
        content.layer?.borderWidth = 1
        content.layer?.borderColor = NSColor.separatorColor.cgColor
        panel.contentView = content

        label.font = .systemFont(ofSize: 19, weight: .semibold)
        label.alignment = .center
        label.frame = content.bounds.insetBy(dx: 3, dy: 8)
        content.addSubview(label)
        super.init(window: panel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(mode: InputLanguageMode, caretFrame: NSRect) {
        guard let window else { return }
        hideWorkItem?.cancel()
        label.stringValue = mode == .chinese ? "中" : "英"
        position(window, near: caretFrame)
        window.orderFrontRegardless()

        let workItem = DispatchWorkItem { [weak self] in self?.window?.orderOut(nil) }
        hideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: workItem)
    }

    func hide() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        window?.orderOut(nil)
    }

    private func position(_ window: NSWindow, near caret: NSRect) {
        let screen = NSScreen.screens.first { $0.visibleFrame.intersects(caret) }
            ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        var origin = NSPoint(x: caret.maxX + 8, y: caret.maxY + 6)
        origin.x = min(max(origin.x, visible.minX + 6), visible.maxX - window.frame.width - 6)
        origin.y = min(max(origin.y, visible.minY + 6), visible.maxY - window.frame.height - 6)
        window.setFrameOrigin(origin)
    }
}
