import AppKit
import SwiftUI

// MARK: - 便签（QuickNote）
//
// ⌃⌘N 调出小窗口，居中弹出，直接打字，自动保存，Esc 退出。
// 复用 swift-markdown-engine 的完整 Markdown 编辑器（所见即所得）。
//
// 自动保存逻辑：
//   · 每次 text 变化后 800ms 防抖 → 存库
//   · 第一次保存用 createMarkdownShot（新建）
//   · 后续保存用 saveContent（更新）
//   · 窗口关闭时立即 flush

// MARK: - 面板

@MainActor
final class QuickNotePanel: NSPanel {

    private var localMonitor: Any?
    private var saveTask: Task<Void, Never>?
    private var currentShotID: Int64?
    private var lastSavedText = ""

    private let store: ShotStore

    init(store: ShotStore = .shared) {
        self.store = store
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        title = "便签"
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        setContentSize(NSSize(width: 600, height: 400))

        let view = QuickNoteView(
            onSave: { [weak self] text in
                self?.updateText(text)
            }
        )
        let hosting = NSHostingController(rootView: view)
        contentView = hosting.view
    }

    required init?(coder: NSCoder) { fatalError() }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func show() {
        // 屏幕正中间
        if let screen = NSScreen.main {
            let size = frame.size
            let x = screen.frame.midX - size.width / 2
            let y = screen.frame.midY - size.height / 2
            setFrameOrigin(NSPoint(x: x, y: y))
        }
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
        installMonitor()
        // 等视图层级建立后聚焦到文本编辑器
        DispatchQueue.main.async { [weak self] in
            guard let self, let textView = Self.findTextView(in: self.contentView) else { return }
            self.makeFirstResponder(textView)
        }
    }

    /// 递归查找 NSHostingView 里的 NSTextView。
    private static func findTextView(in view: NSView?) -> NSTextView? {
        guard let view else { return nil }
        if let textView = view as? NSTextView { return textView }
        for sub in view.subviews {
            if let found = findTextView(in: sub) { return found }
        }
        return nil
    }

    override func close() {
        removeMonitor()
        // 关闭时 flush 未保存的内容
        saveTask?.cancel()
        if let text = currentText, text != lastSavedText, !text.isEmpty {
            persist(text)
        }
        orderOut(nil)
    }

    // MARK: 自动保存

    private var currentText: String? {
        // 从 NSHostingController 的 rootView 拿不到 @State，
        // 用闭包回调的方式在 QuickNoteView 里同步
        lastText
    }
    private var lastText = ""

    func updateText(_ text: String) {
        lastText = text
        // 防抖 800ms
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled, let self else { return }
            self.persist(text)
        }
    }

    private func persist(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do {
            if let shotID = currentShotID {
                try store.saveContent(for: shotID, kind: .markdown, payload: .markdown(text), updateKind: false)
            } else {
                let title = String(text.prefix(30).replacingOccurrences(of: "\n", with: " "))
                let shot = try store.createMarkdownShot(title: title.isEmpty ? "便签" : title, source: text)
                currentShotID = shot.id
            }
            lastSavedText = text
        } catch {
            NSLog("[Index] 便签保存失败: \(error)")
        }
    }

    // MARK: Esc 关闭

    private func installMonitor() {
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return event }
                if event.keyCode == 53 { // Esc
                    self.close()
                    return nil
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

// MARK: - SwiftUI 视图

struct QuickNoteView: View {
    @State private var text = ""
    let onSave: (String) -> Void

    var body: some View {
        MarkdownEditorSurface(text: $text)
            .padding(16)
            .background(Color(nsColor: .textBackgroundColor))
            .onChange(of: text) { _, newValue in
                onSave(newValue)
            }
    }
}

// MARK: - 协调器

@MainActor
final class QuickNoteCoordinator {

    static let shared = QuickNoteCoordinator()

    private var panel: QuickNotePanel?

    func toggle() {
        if let panel, panel.isVisible {
            panel.close()
            return
        }
        show()
    }

    func show() {
        if panel == nil {
            panel = QuickNotePanel()
        }
        panel?.show()
    }

    func close() {
        panel?.close()
    }
}
