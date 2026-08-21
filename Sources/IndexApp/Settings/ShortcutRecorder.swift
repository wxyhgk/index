import SwiftUI
import AppKit

/// 快捷键录制控件。点一下进入录制，按下的下一个组合键就是新快捷键。
struct ShortcutRecorder: NSViewRepresentable {

    @Binding var shortcut: KeyboardShortcut

    func makeNSView(context: Context) -> RecorderView {
        let view = RecorderView()
        view.shortcut = shortcut
        view.onChange = { shortcut = $0 }
        return view
    }

    func updateNSView(_ view: RecorderView, context: Context) {
        view.shortcut = shortcut
        view.needsDisplay = true
    }
}

final class RecorderView: NSView {

    var shortcut: KeyboardShortcut = .captureDefault
    var onChange: ((KeyboardShortcut) -> Void)?

    private var isRecording = false {
        didSet { needsDisplay = true }
    }

    /// 与 SettingsShortcuts 的 recorderSize（130×24）保持一致。
    override var intrinsicContentSize: NSSize { NSSize(width: 130, height: 24) }
    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        isRecording = true
    }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }

        // ESC 放弃录制，Delete 清空后恢复默认。
        if event.keyCode == 53 {
            isRecording = false
            window?.makeFirstResponder(nil)
            return
        }

        let candidate = KeyboardShortcut(event: event)
        // 没有修饰键的话会把普通打字全劫走，直接忽略。
        guard candidate.isValid else { NSSound.beep(); return }

        shortcut = candidate
        onChange?(candidate)
        isRecording = false
        window?.makeFirstResponder(nil)
    }

    /// 只按了修饰键不算数，等真正的字符键。
    override func flagsChanged(with event: NSEvent) {
        if isRecording { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        let box = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: box, xRadius: DS.radiusSmall, yRadius: DS.radiusSmall)

        (isRecording
            ? NSColor.controlAccentColor.withAlphaComponent(0.15)
            : NSColor.controlBackgroundColor).setFill()
        path.fill()

        (isRecording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.lineWidth = isRecording ? DS.strokeEmphasis : DS.hairline
        path.stroke()

        let text = isRecording ? "按下新的组合键…" : shortcut.displayString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: isRecording ? 11 : 13, weight: .medium),
            .foregroundColor: isRecording ? NSColor.controlAccentColor : NSColor.labelColor
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        (text as NSString).draw(
            at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2),
            withAttributes: attrs
        )
    }
}
