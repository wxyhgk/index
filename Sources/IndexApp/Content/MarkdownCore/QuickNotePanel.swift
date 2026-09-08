import AppKit
import SwiftUI
import Combine

// MARK: - 便签面板（QuickNote）
//
// ⌃⌘N 呼出，双栏布局：左侧便签列表（按天分组）+ 右侧 Markdown 编辑器。
// 打开即写：默认焦点在编辑器，直接打字，800ms 防抖静默保存。
// 无文件夹、无目录树。⌘S 保存，⌘N 新建，↑↓ 切换，Esc 关闭。
//
// 本文件只保留窗口壳（NSPanel 配置 / show / close / 动画 / 位置记忆 / 键盘事件）
// 和 SwiftUI 视图（纯渲染）。业务状态与逻辑全部在 QuickNoteViewModel。

// MARK: - 面板

@MainActor
final class QuickNotePanel: NSPanel {

    let viewModel: QuickNoteViewModel

    private var localMonitor: Any?
    private var isClosing = false

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
        level = .normal
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        setContentSize(NSSize(width: 720, height: 480))

        let view = QuickNoteView(viewModel: self.viewModel)
        let hosting = NSHostingController(rootView: view)
        contentView = hosting.view
    }

    required init?(coder: NSCoder) { fatalError() }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    // MARK: 窗口

    func show() {
        if !setFrameUsingName("IndexQuickNote") {
            if let screen = NSScreen.main {
                let size = frame.size
                let x = screen.frame.midX - size.width / 2
                let y = screen.frame.midY - size.height / 2
                setFrameOrigin(NSPoint(x: x, y: y))
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
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
                NSApp.hide(nil)
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
                // Esc 关闭
                if event.keyCode == 53, event.modifierFlags.isEmpty {
                    self.close()
                    return nil
                }
                // ⌘S 保存
                if event.keyCode == 1, event.modifierFlags.contains(.command) {
                    vm.persistNow()
                    return nil
                }
                // ⌘N 新建
                if event.keyCode == 45, event.modifierFlags.contains(.command) {
                    vm.newNote()
                    return nil
                }
                // ⌘\ 切换侧边栏
                if event.keyCode == 39, event.modifierFlags.contains(.command) {
                    vm.toggleSidebar()
                    return nil
                }
                // ⌘V 剪贴板直录（编辑器为空时）
                if event.keyCode == 9, event.modifierFlags.contains(.command) {
                    if vm.pasteClipboardIfEmpty() { return nil }
                }
                // ⌘Z 撤销 / ⇧⌘Z 重做
                if event.keyCode == 6, event.modifierFlags.contains(.command) {
                    if event.modifierFlags.contains(.shift) {
                        vm.redo()
                    } else {
                        vm.undo()
                    }
                    return nil
                }
                // ↑↓ 切换便签（无修饰键）
                if event.modifierFlags.isEmpty {
                    if event.keyCode == 126 { // ↑
                        vm.navigate(direction: -1)
                        return nil
                    }
                    if event.keyCode == 125 { // ↓
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

// MARK: - SwiftUI 视图

struct QuickNoteView: View {
    @ObservedObject var viewModel: QuickNoteViewModel

    @State private var hoveredShotID: Int64?

    var body: some View {
        HStack(spacing: 0) {
            if !viewModel.sidebarCollapsed {
                sidebar
                    .frame(width: 220)

                Divider()
            }

            editor
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: DS.windowBase))
        .onAppear {
            viewModel.onAppear()
        }
        .onChange(of: viewModel.searchQuery) { _, _ in
            viewModel.searchChanged()
        }
        .onReceive(viewModel.libraryDidChangePublisher) {
            viewModel.reload()
        }
    }

    // MARK: 左侧栏

    private var sidebar: some View {
        VStack(spacing: 0) {
            // 顶部：搜索 + 新建
            HStack(spacing: 6) {
                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11, weight: .thin))
                        .foregroundStyle(.secondary)
                    TextField("搜索", text: $viewModel.searchQuery)
                        .font(.system(size: 12, design: .rounded))
                        .textFieldStyle(.plain)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 6))

                Button(action: { viewModel.newNote() }) {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary)
                        .frame(width: 24, height: 24)
                        .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .help("新建便签 (⌘N)")
            }
            .padding(10)

            Divider()

            // 列表
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    // 置顶
                    let pinned = viewModel.shots.filter { viewModel.isPinned($0) }
                    if !pinned.isEmpty {
                        Text("置顶")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                            .padding(.top, 8)
                            .padding(.bottom, 2)

                        ForEach(pinned) { shot in
                            sidebarRow(shot)
                        }

                        Divider().padding(.horizontal, 10).padding(.vertical, 4)
                    }

                    // 按天分组（排除已置顶的）
                    let unpinned = viewModel.shots.filter { !viewModel.isPinned($0) }
                    let grouped = QuickNoteViewModel.groupByDay(unpinned)
                    ForEach(grouped, id: \.date) { group in
                        Text(QuickNoteViewModel.dayLabel(for: group.date))
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                            .padding(.top, 8)
                            .padding(.bottom, 2)

                        ForEach(group.shots) { shot in
                            sidebarRow(shot)
                        }
                    }
                }
                .padding(.bottom, 8)
            }
        }
        .background(Color(nsColor: DS.windowBase))
    }

    private func sidebarRow(_ shot: Shot) -> some View {
        let isSelected = viewModel.selectedShotID == shot.id
        let isHovered = hoveredShotID == shot.id
        let isConfirmDelete = viewModel.confirmDeleteID == shot.id
        let isPinned = viewModel.isPinned(shot)
        return HStack(spacing: 6) {
            // 图钉（置顶时始终显示，hover 时也可操作）
            if isPinned || isHovered {
                Button(action: { viewModel.togglePin(shot) }) {
                    Image(systemName: isPinned ? "pin.fill" : "pin")
                        .font(.system(size: 8, weight: .thin))
                        .foregroundStyle(isPinned ? .primary : .tertiary)
                        .frame(width: 12, height: 12)
                }
                .buttonStyle(.plain)
                .help(isPinned ? "取消置顶" : "置顶")
            }

            Text(viewModel.shotTitle(for: shot))
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(isSelected ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer()

            if isHovered {
                Button(action: {
                    if isConfirmDelete {
                        viewModel.deleteShot(shot.id ?? 0)
                    } else {
                        viewModel.confirmDeleteID = shot.id
                        Task { @MainActor in
                            try? await Task.sleep(for: .seconds(2))
                            if viewModel.confirmDeleteID == shot.id {
                                viewModel.confirmDeleteID = nil
                            }
                        }
                    }
                }) {
                    Image(systemName: isConfirmDelete ? "trash.fill" : "xmark")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(isConfirmDelete ? .red : .secondary)
                        .frame(width: 16, height: 16)
                        .background(Color(nsColor: .textBackgroundColor))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .help(isConfirmDelete ? "再点一次确认删除" : "删除")
                .transition(.opacity)
            } else {
                Text(viewModel.timeLabel(shot.capturedAt))
                    .font(.system(size: 9, design: .rounded))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            isSelected
                ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.15)
                : Color.clear
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture {
            if let id = shot.id {
                viewModel.select(shotID: id)
            }
        }
        .onTapGesture(count: 2) { viewModel.copyShot(shot) }
        .onHover { hovering in
            hoveredShotID = hovering ? shot.id : (hoveredShotID == shot.id ? nil : hoveredShotID)
            if !hovering {
                viewModel.confirmDeleteID = nil
            }
        }
    }

    // MARK: 右侧编辑器

    private var editor: some View {
        VStack(spacing: 0) {
            // 顶栏
            HStack {
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        viewModel.toggleSidebar()
                    }
                }) {
                    Image(systemName: "sidebar.leading")
                        .font(.system(size: 12, weight: .thin))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .help("切换侧边栏 (⌘\\)")

                Text(viewModel.selectedTitle)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            Divider()

            // 编辑器
            MarkdownEditorSurface(text: $viewModel.text)
                .padding(14)

            // 待办清单（解析 - [ ] / - [x]）
            let todos = viewModel.todos
            if !todos.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(todos.indices, id: \.self) { i in
                        TodoRow(
                            item: todos[i],
                            onToggle: {
                                viewModel.toggleTodo(at: i)
                            }
                        )
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }

            // 工具栏（flomo 风格）
            Divider()
            HStack(spacing: 0) {
                toolbarButton("textformat", help: "标题 (## )") { viewModel.insertSyntax("## ") }
                toolbarButton("list.bullet", help: "无序列表 (- )") { viewModel.insertSyntax("- ") }
                toolbarButton("list.number", help: "有序列表 (1. )") { viewModel.insertSyntax("1. ") }
                toolbarButton("checklist", help: "待办 (- [ ] )") { viewModel.insertSyntax("- [ ] ") }
                toolbarButton("photo", help: "图片 (![]())") { viewModel.insertSyntax("![描述]()") }

                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func toolbarButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .thin))
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

// MARK: - 待办行

struct TodoRow: View {
    let item: TodoItem
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onToggle) {
                Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13))
                    .foregroundStyle(item.done ? .green : .secondary)
            }
            .buttonStyle(.plain)

            Text(item.text)
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(item.done ? .tertiary : .primary)
                .strikethrough(item.done)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
    }
}

// MARK: - 协调器

@MainActor
final class QuickNoteCoordinator {

    static let shared = QuickNoteCoordinator()

    private var panel: QuickNotePanel?

    /// ⌃⌘N：新建便签（打开面板 + 清空编辑器）
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

    /// ⌃⇧⌘N：继续上次便签（打开面板 + 加载最近一条）
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
