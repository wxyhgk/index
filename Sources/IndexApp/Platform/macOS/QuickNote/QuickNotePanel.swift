import AppKit
import SwiftUI
import Combine

// MARK: - 便签面板（NSPanel 窗口壳 + 协调器）
//
// 平台窗口副作用收口在 Platform/：NSPanel 配置、show/close 动画、
// NSEvent 键盘监听、位置记忆。SwiftUI 视图（QuickNoteView）在 Content 层。

@MainActor
final class QuickNotePanel: NSPanel {

    let viewModel: QuickNoteViewModel

    private var localMonitor: Any?
    private var isClosing = false
    private var cancellables = Set<AnyCancellable>()

    init(viewModel: QuickNoteViewModel? = nil) {
        self.viewModel = viewModel ?? QuickNoteViewModel()
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        title = "便签"
        isFloatingPanel = false
        level = self.viewModel.isFloating ? .floating : .normal
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        setContentSize(NSSize(width: 720, height: 480))

        let view = QuickNoteView(viewModel: self.viewModel)
        let hosting = NSHostingController(rootView: view)
        contentView = hosting.view

        self.viewModel.$isFloating
            .dropFirst()
            .sink { [weak self] floating in
                self?.applyFloating(floating)
            }
            .store(in: &cancellables)

        self.viewModel.$selectedShotID
            .dropFirst()
            .sink { [weak self] _ in
                self?.saveCurrentCursor()
                DispatchQueue.main.async { self?.restoreCursor() }
            }
            .store(in: &cancellables)
    }

    private func applyFloating(_ floating: Bool) {
        level = floating ? .floating : .normal
    }

    // MARK: 光标位置记忆

    private func saveCurrentCursor() {
        guard let textView = Self.findTextView(in: contentView) else { return }
        viewModel.saveCursorPosition(textView.selectedRange().location)
    }

    private func restoreCursor() {
        guard let textView = Self.findTextView(in: contentView),
              let id = viewModel.selectedShotID,
              let location = viewModel.cursorPosition(for: id) else { return }
        let maxLoc = textView.string.count
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
        NSApp.activate(ignoringOtherApps: true)
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
        makeKeyAndOrderFront(nil)
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
                self?.orderOut(nil)
                self?.alphaValue = 1
                self?.isClosing = false
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
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return event }
                let vm = self.viewModel
                if event.keyCode == 53, event.modifierFlags.isEmpty {
                    self.close()
                    return nil
                }
                if event.keyCode == 1, event.modifierFlags.contains(.command) {
                    vm.persistNow()
                    return nil
                }
                if event.keyCode == 45, event.modifierFlags.contains(.command) {
                    vm.newNote()
                    return nil
                }
                if event.keyCode == 39, event.modifierFlags.contains(.command) {
                    vm.toggleSidebar()
                    return nil
                }
                if event.keyCode == 9, event.modifierFlags.contains(.command) {
                    if vm.pasteClipboardIfEmpty() { return nil }
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
    }

    private func removeMonitor() {
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
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
}
