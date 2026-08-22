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
    /// 钉住模式：点击外部不关闭。
    var isPinned = false {
        didSet {
            if isPinned {
                removeGlobalMonitor()
            } else {
                installGlobalMonitor()
            }
        }
    }

    init(store: ClipboardHistoryStore, viewModel: ClipboardHistoryViewModel? = nil) {
        self.store = store
        let resolvedViewModel = viewModel ?? ClipboardHistoryViewModel.shared
        self.viewModel = resolvedViewModel
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
        isMovable = true

        let root = ClipboardHistoryView(viewModel: resolvedViewModel, store: store)
        let hosting = NSHostingController(rootView: root)
        hosting.view.wantsLayer = true
        hosting.view.layer?.cornerRadius = DS.radiusPanel
        hosting.view.layer?.masksToBounds = true
        contentView = hosting.view
    }

    required init?(coder: NSCoder) { fatalError() }

    override var canBecomeKey: Bool { true }

    func show() {
        viewModel.refresh()
        // 用鼠标所在的屏幕定位面板（多显示器/Sidecar 场景）。
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouseLocation) } ?? NSScreen.main
        // 优先用上次保存的相对位置（比例），在目标屏幕上还原。
        // clamp 到 [0.1, 0.9] 防止拖到屏幕外后无法找回。
        if let screen, let raw = savedRelativePosition {
            let relative = CGPoint(
                x: min(max(raw.x, 0.1), 0.9),
                y: min(max(raw.y, 0.1), 0.9)
            )
            let origin = NSPoint(
                x: screen.frame.minX + relative.x * screen.frame.width - frame.width / 2,
                y: screen.frame.minY + relative.y * screen.frame.height - frame.height / 2
            )
            setFrameOrigin(origin)
        } else if let screen {
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
        // 键盘导航：Esc 关闭，←→ 选择，Enter 粘贴，Delete 删除，空格 大图预览。
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] (event: NSEvent) -> NSEvent? in
            guard let self else { return event }
            // 焦点在文本输入框内时，放行按键给文本框（退格、方向键等）
            if let responder = self.firstResponder, responder is NSText {
                return event
            }
            // 空格键：按下显示大图，松开隐藏（类似 Finder Quick Look）。
            // isARepeat 过滤：按住不放时系统连续发 keyDown，只在第一次按下时定位，
            // 否则图片会跟着鼠标移动（每次 repeat 都用新的 mouseLocation 重新定位）。
            if event.keyCode == 49 {
                if event.type == .keyDown, !event.isARepeat {
                    self.showPreviewForSelection()
                } else if event.type == .keyUp {
                    ImagePreviewController.shared.cancel()
                }
                return nil
            }
            guard event.type == .keyDown else { return event }
            // Esc 始终关闭面板
            if event.keyCode == 53 {
                self.close()
                return nil
            }
            switch event.keyCode {
            case 123: // ←
                self.viewModel.moveSelection(-1)
                return nil
            case 124: // →
                self.viewModel.moveSelection(1)
                return nil
            case 36: // Enter = 粘贴选中项
                self.viewModel.pasteSelected()
                return nil
            case 51, 117: // Delete / Forward Delete
                self.viewModel.deleteSelected()
                return nil
            default:
                return event
            }
        }
        if !isPinned {
            installGlobalMonitor()
        }
    }

    /// 空格键触发：选中项是图片时显示大图预览。
    private func showPreviewForSelection() {
        let visible = viewModel.filteredItems
        guard viewModel.selectedIndex < visible.count else { return }
        let item = visible[viewModel.selectedIndex]
        guard item.kind == .image,
              let id = item.id,
              let thumbnail = viewModel.imageThumbnails[id]
        else { return }
        ImagePreviewController.shared.showNow(image: thumbnail, screenPoint: NSEvent.mouseLocation)
    }

    /// 点击面板外部时关闭（非钉住模式）。
    /// 用位置检查代替时间宽限：NSApp.activate 异步完成前 WindowServer
    /// 可能把点击路由给之前的前台应用，但鼠标位置不会变——
    /// 只要鼠标在面板 frame 内就不关闭。
    private func installGlobalMonitor() {
        guard globalMonitor == nil else { return }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, self.isVisible, !self.isPinned else { return }
            // 鼠标在面板内 → 不关闭（即使事件被路由到了其他应用）。
            let mouseLocation = NSEvent.mouseLocation
            if self.frame.contains(mouseLocation) {
                return
            }
            self.close()
        }
    }

    private func removeGlobalMonitor() {
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
            globalMonitor = nil
        }
    }

    private func removeMonitors() {
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
        removeGlobalMonitor()
    }

    /// 上次保存的相对位置（0-1 比例），适配多显示器/分辨率变化。
    private var savedRelativePosition: CGPoint? {
        guard UserDefaults.standard.bool(forKey: "clipboardPanelPositionSaved") else { return nil }
        let x = UserDefaults.standard.double(forKey: "clipboardPanelRelX")
        let y = UserDefaults.standard.double(forKey: "clipboardPanelRelY")
        return CGPoint(x: x, y: y)
    }

    override func close() {
        // 面板关闭时取消图片预览，避免预览窗残留。
        ImagePreviewController.shared.cancel()
        // 保存相对位置（比例），下次打开时按当前主屏尺寸还原。
        if let screen = NSScreen.main {
            let relX = (frame.midX - screen.frame.minX) / screen.frame.width
            let relY = (frame.midY - screen.frame.minY) / screen.frame.height
            UserDefaults.standard.set(relX, forKey: "clipboardPanelRelX")
            UserDefaults.standard.set(relY, forKey: "clipboardPanelRelY")
            UserDefaults.standard.set(true, forKey: "clipboardPanelPositionSaved")
        }
        removeMonitors()
        super.close()
        onClose?()
    }
}
