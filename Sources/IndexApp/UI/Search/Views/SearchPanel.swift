import AppKit
import SwiftUI

// MARK: - Option+Space 全局搜索面板
//
// Spotlight 风格：居中弹出，搜索框 + 统一结果列表 + 右侧预览。
// Esc 关闭，↑↓ 选择，点击外部关闭。

@MainActor
final class SearchPanel: NSPanel {

    var onClose: (() -> Void)?

    private let viewModel: SearchPanelViewModel
    private var localMonitor: Any?
    private var globalMonitor: Any?

    init(viewModel: SearchPanelViewModel) {
        self.viewModel = viewModel
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 420),
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
        isMovable = false

        let root = SearchPanelView(viewModel: viewModel)
        let hosting = NSHostingController(rootView: root)
        hosting.view.wantsLayer = true
        hosting.view.layer?.cornerRadius = DS.radiusPanel
        hosting.view.layer?.masksToBounds = true
        contentView = hosting.view
    }

    required init?(coder: NSCoder) { fatalError() }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func show() {
        viewModel.clear()
        viewModel.loadRecent()
        // 屏幕正中间
        if let screen = NSScreen.main {
            let size = frame.size
            let x = screen.frame.midX - size.width / 2
            let y = screen.frame.midY - size.height / 2
            setFrameOrigin(NSPoint(x: x, y: y))
        }
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
        installMonitors()
    }

    override func close() {
        removeMonitors()
        orderOut(nil)
        onClose?()
    }

    // MARK: 键盘/鼠标监听

    private func installMonitors() {
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            MainActor.assumeIsolated { self?.handleKey(event) ?? event }
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isVisible else { return }
                let mouseLocation = NSEvent.mouseLocation
                if !self.frame.contains(mouseLocation) {
                    self.close()
                }
            }
        }
    }

    private func removeMonitors() {
        if let monitor = localMonitor { NSEvent.removeMonitor(monitor) }
        localMonitor = nil
        if let monitor = globalMonitor { NSEvent.removeMonitor(monitor) }
        globalMonitor = nil
    }

    private func handleKey(_ event: NSEvent) -> NSEvent? {
        // 文本输入时：Esc / ↑↓ 拦截，其余放行（打字）
        if let responder = firstResponder, responder is NSText {
            switch event.keyCode {
            case 53:  // Esc
                close()
                return nil
            case 126: // ↑
                viewModel.moveSelection(-1)
                return nil
            case 125: // ↓
                viewModel.moveSelection(1)
                return nil
            default:
                return event
            }
        }
        switch event.keyCode {
        case 53: // Esc
            close()
            return nil
        case 126: // ↑
            viewModel.moveSelection(-1)
            return nil
        case 125: // ↓
            viewModel.moveSelection(1)
            return nil
        default:
            return event
        }
    }
}

// MARK: - 搜索面板协调器

@MainActor
final class SearchPanelCoordinator {
    static let shared = SearchPanelCoordinator()

    private var panel: SearchPanel?
    private let viewModel = SearchPanelViewModel()

    func togglePanel() {
        if let panel, panel.isVisible {
            panel.close()
            return
        }
        showPanel()
    }

    func showPanel() {
        if panel == nil {
            panel = SearchPanel(viewModel: viewModel)
            panel?.onClose = { [weak self] in
                self?.panel = nil
            }
        }
        panel?.show()
    }

    func closePanel() {
        panel?.close()
    }
}
