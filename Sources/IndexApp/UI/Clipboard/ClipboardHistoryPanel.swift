import AppKit
import SwiftUI

// ============================================================
// MARK: - 剪贴板历史浮动面板
//
// Paste 式设计：横向卡片流，彩色标题栏（类型+时间+来源），
// 键盘导航（←→ 选择 + Enter 复制 + Delete 删除），类型过滤。
//
// 窗口用 nonactivatingPanel（不跳 Dock），但 show 时手动激活
// 让面板成为 key window 接收键盘事件。点击面板外面自动关闭。
// ============================================================

@MainActor
final class ClipboardHistoryPanel: NSPanel {

    private let store: ClipboardHistoryStore
    var onClose: (() -> Void)?
    var onPanelShown: (() -> Void)?

    private var viewModel: ClipboardHistoryViewModel!
    private var localMonitor: Any?
    private var globalMonitor: Any?

    init(store: ClipboardHistoryStore) {
        self.store = store
        self.viewModel = ClipboardHistoryViewModel(store: store)
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 320),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false

        let root = ClipboardHistoryView(viewModel: viewModel, store: store)
        let hosting = NSHostingController(rootView: root)
        hosting.view.wantsLayer = true
        hosting.view.layer?.cornerRadius = DS.radiusCard
        hosting.view.layer?.masksToBounds = true
        contentView = hosting.view
    }

    required init?(coder: NSCoder) { fatalError() }

    override var canBecomeKey: Bool { true }

    func show() {
        viewModel.refresh()
        if let screen = NSScreen.main {
            let size = frame.size
            let origin = NSPoint(
                x: screen.frame.midX - size.width / 2,
                y: screen.frame.midY - size.height / 2 + 40
            )
            setFrameOrigin(origin)
        }
        // 激活 app 让面板成为 key window（LSUIElement 不跳 Dock）
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
        resetScrollPosition()
        installMonitors()
        onPanelShown?()
    }

    /// 重置卡片流的横向滚动位置到最左边（关闭再打开时回到初始状态）。
    private func resetScrollPosition() {
        guard let content = contentView else { return }
        for scrollView in allScrollViews(in: content) {
            guard let docView = scrollView.documentView,
                  docView.bounds.width > scrollView.contentView.bounds.width + 1
            else { continue }
            scrollView.contentView.scroll(to: .zero)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    private func allScrollViews(in view: NSView) -> [NSScrollView] {
        var result: [NSScrollView] = []
        if let sv = view as? NSScrollView { result.append(sv) }
        for sub in view.subviews {
            result.append(contentsOf: allScrollViews(in: sub))
        }
        return result
    }

    private func installMonitors() {
        removeMonitors()
        // 键盘导航：Esc 关闭，←→ 选择，Enter 复制，Delete 删除。
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            // Esc 始终关闭面板
            if event.keyCode == 53 {
                self.close()
                return nil
            }
            // 焦点在文本输入框内时，放行按键给文本框（退格、方向键等）
            if let responder = self.firstResponder, responder is NSText {
                return event
            }
            switch event.keyCode {
            case 123: // ←
                self.viewModel.moveSelection(-1)
                return nil
            case 124: // →
                self.viewModel.moveSelection(1)
                return nil
            case 36: // Enter
                self.viewModel.copySelected()
                return nil
            case 51, 117: // Delete / Forward Delete
                self.viewModel.deleteSelected()
                return nil
            default:
                return event
            }
        }
        // 点击面板外面关闭
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, self.isVisible else { return }
            self.close()
        }
    }

    private func removeMonitors() {
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
            globalMonitor = nil
        }
    }

    override func close() {
        removeMonitors()
        super.close()
        onClose?()
    }
}
