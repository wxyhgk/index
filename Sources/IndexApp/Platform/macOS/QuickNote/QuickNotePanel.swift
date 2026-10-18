import AppKit
import SwiftUI
import Combine

// MARK: - 便签面板（NSPanel 窗口壳 + 协调器）
//
// 平台窗口副作用收口在 Platform/：NSPanel 配置、show/close 动画、
// NSEvent 键盘监听、位置记忆。SwiftUI 视图（QuickNoteView）在 Content 层。

@MainActor
final class QuickNotePanel: FloatingPanel {

    let viewModel: QuickNoteViewModel

    private let monitors = PanelEventMonitors()
    private var isClosing = false
    private var cancellables = Set<AnyCancellable>()

    init(viewModel: QuickNoteViewModel? = nil) {
        let resolved = viewModel ?? QuickNoteViewModel()
        self.viewModel = resolved
        let hosting = NSHostingController(rootView: QuickNoteView(viewModel: resolved))
        super.init(
            spec: PanelSpec.quickNote(size: CGSize(width: 560, height: 420)),
            contentViewController: hosting
        )
        setContentSize(NSSize(width: 560, height: 420))

        self.viewModel.$selectedShotID
            .dropFirst()
            .sink { [weak self] _ in
                self?.saveCurrentCursor()
                DispatchQueue.main.async { self?.restoreCursor() }
            }
            .store(in: &cancellables)
    }

    // MARK: 图片粘贴

    private func pasteImage(name: String) {
        let embed = "![[\(name)]]\n"
        if let textView = Self.findTextView(in: contentView) {
            let range = textView.selectedRange()
            let nsString = textView.string as NSString
            let prefix = nsString.substring(to: range.location)
            let suffix = nsString.substring(from: range.location + range.length)
            viewModel.updateText(prefix + embed + suffix)
            // 恢复光标到插入点之后（UTF-16 偏移）
            DispatchQueue.main.async {
                let newLoc = (prefix as NSString).length + (embed as NSString).length
                textView.setSelectedRange(NSRange(location: min(newLoc, (textView.string as NSString).length), length: 0))
            }
        } else {
            viewModel.insertImage(name: name)
        }
    }

    // MARK: 光标位置记忆

    private func saveCurrentCursor() {
        guard let textView = Self.findTextView(in: contentView),
              let oldID = viewModel.pendingCursorShotID else { return }
        viewModel.saveCursorPosition(textView.selectedRange().location, for: oldID)
    }

    private func restoreCursor() {
        guard let textView = Self.findTextView(in: contentView),
              let id = viewModel.selectedShotID,
              let location = viewModel.cursorPosition(for: id) else { return }
        let maxLoc = (textView.string as NSString).length
        textView.setSelectedRange(NSRange(location: min(location, maxLoc), length: 0))
    }

    required init?(coder: NSCoder) { fatalError() }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    // MARK: 窗口

    func show() {
        if isClosing {
            isClosing = false
            alphaValue = 1
        }
        if !isVisible {
            if !setFrameUsingName("IndexQuickNote") {
                if let screen = NSScreen.main {
                    let size = frame.size
                    let x = screen.frame.midX - size.width / 2
                    let y = screen.frame.midY - size.height / 2
                    setFrameOrigin(NSPoint(x: x, y: y))
                }
            }
        }
        // 不能调用 NSApp.activate：台前调度会把图库等所有 Index 窗口一起带出来。
        // orderFrontRegardless + makeKey 让面板拿键盘焦点而不激活整个 App。
        let targetFrame = frame
        let scale: CGFloat = 0.98
        let scaledWidth = targetFrame.width * scale
        let scaledHeight = targetFrame.height * scale
        let scaledFrame = NSRect(
            x: targetFrame.midX - scaledWidth / 2,
            y: targetFrame.midY - scaledHeight / 2,
            width: scaledWidth,
            height: scaledHeight
        )
        alphaValue = 0
        setFrame(scaledFrame, display: false)
        presentWithoutActivating()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            alphaValue = 1
            setFrame(targetFrame, display: true)
        }
        installMonitor()
        DispatchQueue.main.async { [weak self] in
            guard let self, let textView = Self.findTextView(in: self.contentView) else { return }
            textView.allowsUndo = true
            self.makeFirstResponder(textView)
        }
    }

    override func close() {
        guard !isClosing else { return }
        isClosing = true
        removeMonitor()
        viewModel.flushPendingSave()
        setFrameUsingName("IndexQuickNote")
        NSAnimationContext.runAnimationGroup({ (context: NSAnimationContext) in
            context.duration = 0.15
            self.alphaValue = 0
        }, completionHandler: { [weak self] in
            DispatchQueue.main.async {
                // show() 可能已取消关闭（isClosing 被重置为 false），此时不 orderOut
                guard let self, self.isClosing else { return }
                self.orderOut(nil)
                self.alphaValue = 1
                self.isClosing = false
            }
        })
    }

    // MARK: 焦点

    private static func findTextView(in view: NSView?) -> NSTextView? {
        guard let view else { return nil }
        if let textView = view as? NSTextView { return textView }
        for sub in view.subviews {
            if let found = findTextView(in: sub) { return found }
        }
        return nil
    }

    // MARK: 键盘事件

    private func installMonitor() {
        removeMonitor()
        monitors.installLocalKey { [weak self] event in
            guard let self else { return event }
            let vm = self.viewModel
            // Esc 只在面板是 key window 时拦截，避免图库等窗口按 Esc 误关便签
            if event.keyCode == 53, event.modifierFlags.isEmpty, self.isKeyWindow {
                self.close()
                return nil
            }
            if event.keyCode == 1, event.modifierFlags.contains(.command) {
                vm.persistNow()
                return nil
            }
            if event.keyCode == 45, event.modifierFlags.contains(.command), !event.modifierFlags.contains(.control) {
                vm.newNote()
                return nil
            }
            if event.keyCode == 39, event.modifierFlags.contains(.command) {
                vm.toggleSidebar()
                return nil
            }
            if event.keyCode == 9, event.modifierFlags.contains(.command) {
                // 剪贴板有图片时导入图库 + 在光标位置插入 ![[sha256]]
                if let sha = QuickNoteImageStore.importClipboardImage() {
                    self.pasteImage(name: sha)
                    return nil
                }
                if vm.pasteClipboardText() { return nil }
            }
            if event.keyCode == 6, event.modifierFlags.contains(.command) {
                if event.modifierFlags.contains(.shift) {
                    vm.redo()
                } else {
                    vm.undo()
                }
                return nil
            }
            if event.modifierFlags.isEmpty {
                if event.keyCode == 126 {
                    vm.navigate(direction: -1)
                    return nil
                }
                if event.keyCode == 125 {
                    vm.navigate(direction: 1)
                    return nil
                }
            }
            return event
        }
    }

    private func removeMonitor() {
        monitors.removeAll()
    }
}

// MARK: - 导出

@MainActor
enum QuickNoteExporter {
    @discardableResult
    static func exportMarkdown(_ text: String, suggestedName: String) -> Bool {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName.hasSuffix(".md") ? suggestedName : "\(suggestedName).md"
        panel.allowedContentTypes = [.init(filenameExtension: "md")!]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return true
        } catch {
            NSLog("[Index] 便签导出失败: \(error)")
            return false
        }
    }
}

// MARK: - 协调器

@MainActor
final class QuickNoteCoordinator {

    static let shared = QuickNoteCoordinator()

    private var panel: QuickNotePanel?

    func showNew() {
        if let panel, panel.isVisible {
            if NSApp.isActive {
                panel.close()
            } else {
                panel.show()
            }
            return
        }
        if panel == nil {
            panel = QuickNotePanel()
        }
        panel?.show()
        panel?.viewModel.resetEditor()
    }

    func showResume() {
        if let panel, panel.isVisible {
            if NSApp.isActive {
                panel.close()
            } else {
                panel.show()
            }
            return
        }
        if panel == nil {
            panel = QuickNotePanel()
        }
        panel?.show()
        panel?.viewModel.loadLatest()
    }

    func close() {
        panel?.close()
    }

    /// App 退出时调用：flush 未落盘的便签文本。
    func flush() {
        panel?.viewModel.flushPendingSave()
    }
}
