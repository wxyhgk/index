import AppKit
import SwiftUI

// ============================================================
// MARK: - 剪贴板历史浮动面板
//
// Paste 式设计：横向卡片流，彩色标题栏（类型+时间+来源），
// 键盘导航（←→ 选择 + Enter 粘贴 + Delete 删除），类型过滤。
//
// 窗口用 nonactivatingPanel：它可以自己成为 key window 接收键盘事件，
// 但不能激活整个 Index、把图库窗口所在的 Stage 一起拉到前台。
// 点击面板外面自动关闭。
// ============================================================

enum ClipboardPanelShortcutCommand: Equatable {
    case close
    case movePrevious
    case moveNext
    case paste
    case pasteAsPlainText
    case copy
    case rename
    case delete
    case previewStart
    case previewEnd
    case consume
}

enum ClipboardPanelShortcutResolver {
    static func command(
        keyCode: UInt16,
        eventType: NSEvent.EventType,
        modifiers: NSEvent.ModifierFlags,
        isRepeat: Bool = false
    ) -> ClipboardPanelShortcutCommand? {
        let relevantModifiers = modifiers.intersection([.command, .shift, .option, .control])

        if keyCode == KeyCode.space, relevantModifiers.isEmpty {
            if eventType == .keyUp { return .previewEnd }
            guard eventType == .keyDown else { return nil }
            return isRepeat ? .consume : .previewStart
        }
        guard eventType == .keyDown else { return nil }

        switch (keyCode, relevantModifiers) {
        case (KeyCode.escape, []): return .close
        case (KeyCode.left, []): return .movePrevious
        case (KeyCode.right, []): return .moveNext
        case (KeyCode.returnKey, []), (KeyCode.keypadEnter, []): return .paste
        case (KeyCode.returnKey, [.shift]), (KeyCode.keypadEnter, [.shift]):
            return .pasteAsPlainText
        case (KeyCode.c, [.command]): return .copy
        case (KeyCode.r, [.command]): return .rename
        case (KeyCode.delete, []), (KeyCode.forwardDelete, []): return .delete
        default: return nil
        }
    }
}

/// 搜索框通常会保留 first responder，以便用户打开面板后直接输入。
/// 不能因此把 Paste 式命令全部交给 NSText；只有真正属于文本编辑的按键
/// （字符、空格、光标移动、退格）才应留在搜索框。卡片标题改名期间则完全
/// 交还原生 field editor，让 Enter/Esc 分别提交和取消改名。
enum ClipboardPanelTextInputShortcutPolicy {
    static func defersToTextInput(
        _ command: ClipboardPanelShortcutCommand,
        isRenaming: Bool
    ) -> Bool {
        if isRenaming { return true }
        switch command {
        case .paste, .pasteAsPlainText, .copy, .rename, .close:
            return false
        case .movePrevious, .moveNext, .delete, .previewStart, .previewEnd, .consume:
            return true
        }
    }
}

@MainActor
final class ClipboardHistoryPanelCommands: ObservableObject {
    @Published private(set) var renameGeneration = 0
    private(set) var isRenaming = false
    var onCardInteraction: (() -> Void)?

    func requestRename() {
        renameGeneration &+= 1
    }

    func setRenaming(_ isRenaming: Bool) {
        self.isRenaming = isRenaming
    }

    func prepareForCardInteraction() {
        onCardInteraction?()
    }
}

@MainActor
final class ClipboardHistoryPanel: NSPanel {

    private let store: ClipboardHistoryStore
    var onClose: (() -> Void)?
    var onPanelShown: (() -> Void)?

    private var viewModel: ClipboardHistoryViewModel!
    private let commands = ClipboardHistoryPanelCommands()
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
        // 浮动面板拥有独立的查询/筛选/键盘选择会话。它与图库里的剪贴板
        // Tab 只共享持久化 store，不能共享一份 UI 状态。
        let resolvedViewModel = viewModel ?? ClipboardHistoryViewModel(store: store)
        self.viewModel = resolvedViewModel
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 320),
            styleMask: [.borderless, .nonactivatingPanel],
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
        becomesKeyOnlyIfNeeded = false
        PanelPlacement.detachFromAppStage(self)
        commands.onCardInteraction = { [weak self] in
            // 卡片的点击由手势识别器完成，不会像原生可选列表那样自动接管
            // first responder。显式结束搜索框的 field editor，随后方向键、
            // Space 和 Delete 才归卡片流处理。
            self?.makeFirstResponder(nil)
        }

        let root = ClipboardHistoryView(
            viewModel: resolvedViewModel,
            commands: commands,
            store: store
        )
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
        // nonactivatingPanel 能在不激活整个 App 的情况下拿键盘焦点。
        // 不能调用 NSApp.activate：台前调度会把图库等所有 Index 窗口一起带出来。
        orderFrontRegardless()
        makeKey()
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
        // 键盘导航集中由纯解析器解释。搜索框拿到 first responder 时仍接管
        // Enter/Shift+Enter/⌘C/⌘R/Esc；重命名输入框则完全保留原生编辑语义。
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] (event: NSEvent) -> NSEvent? in
            guard let self else { return event }
            return self.handleShortcutEvent(event)
        }
        if !isPinned {
            installGlobalMonitor()
        }
    }

    /// 保持为独立事件入口，测试要覆盖真实 first-responder 门，而不只验证 keyCode 表。
    func handleShortcutEvent(_ event: NSEvent) -> NSEvent? {
        guard let command = ClipboardPanelShortcutResolver.command(
                keyCode: event.keyCode,
                eventType: event.type,
                modifiers: event.modifierFlags,
                isRepeat: event.isARepeat
        ) else { return event }
        if firstResponder is NSText,
           ClipboardPanelTextInputShortcutPolicy.defersToTextInput(
               command,
               isRenaming: commands.isRenaming
           ) {
            return event
        }

        NSLog(
            "[Index][ClipboardShortcut] command=%@ keyWindow=%d responder=%@",
            String(describing: command),
            isKeyWindow ? 1 : 0,
            firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        )

        switch command {
        case .close:
            close()
        case .movePrevious:
            viewModel.moveSelection(
                -1,
                preservingQueue: viewModel.isContinuousSelectionEnabled
            )
        case .moveNext:
            viewModel.moveSelection(
                1,
                preservingQueue: viewModel.isContinuousSelectionEnabled
            )
        case .paste:
            viewModel.pasteSelected()
        case .pasteAsPlainText:
            viewModel.pasteSelectedAsPlainText()
        case .copy:
            viewModel.copySelected()
        case .rename:
            commands.requestRename()
        case .delete:
            viewModel.deleteSelected()
        case .previewStart:
            showPreviewForSelection()
        case .previewEnd:
            ImagePreviewController.shared.cancel()
        case .consume:
            break
        }
        return nil
    }

    /// 空格键触发：选中项是图片时显示大图预览。
    private func showPreviewForSelection() {
        let visible = viewModel.filteredItems
        guard viewModel.selectedIndex < visible.count else { return }
        let item = visible[viewModel.selectedIndex]
        guard item.kind == .image,
              let url = viewModel.store.content(of: item).assetURL
        else { return }
        let point = NSEvent.mouseLocation
        if let cached = ThumbnailLoader.shared.cachedImage(forKey: item.thumbnailCacheKey) {
            ImagePreviewController.shared.showNow(image: cached, screenPoint: point)
            return
        }
        Task {
            guard let image = await ThumbnailLoader.shared.load(
                url: url,
                key: item.thumbnailCacheKey
            ), !Task.isCancelled else { return }
            ImagePreviewController.shared.showNow(image: image, screenPoint: point)
        }
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
        let defaults = UserDefaults.standard
        guard defaults.bool(for: PagePreferences.clipboardPanelPositionSaved) else { return nil }
        let x = defaults.double(for: PagePreferences.clipboardPanelRelativeX)
        let y = defaults.double(for: PagePreferences.clipboardPanelRelativeY)
        return CGPoint(x: x, y: y)
    }

    override func close() {
        // 面板关闭时取消图片预览，避免预览窗残留。
        ImagePreviewController.shared.cancel()
        // nonactivatingPanel 可以在目标 App 仍 active 时成为 key window。关闭前先
        // 结束 field editor 并释放 key 状态，让 WindowServer 把输入焦点交还给
        // 原窗口；否则双击和 Enter 随后发出的 ⌘V 会落在“没有 key window”的间隙。
        makeFirstResponder(nil)
        if isKeyWindow {
            resignKey()
        }
        // 保存相对位置（比例），下次打开时按当前主屏尺寸还原。
        if let screen = NSScreen.main {
            let relX = (frame.midX - screen.frame.minX) / screen.frame.width
            let relY = (frame.midY - screen.frame.minY) / screen.frame.height
            let defaults = UserDefaults.standard
            defaults.set(relX, for: PagePreferences.clipboardPanelRelativeX)
            defaults.set(relY, for: PagePreferences.clipboardPanelRelativeY)
            defaults.set(true, for: PagePreferences.clipboardPanelPositionSaved)
        }
        removeMonitors()
        super.close()
        onClose?()
    }
}
