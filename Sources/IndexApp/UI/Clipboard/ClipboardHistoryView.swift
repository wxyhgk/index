import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - 窗口拖拽区域
//
// 用 AppKit 原生 performDrag(with:) 实现，系统级拖动不抖不卡。
// 放在 topBar 的 background 层，不影响按钮/输入框的点击。

private struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        DragAreaView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    final class DragAreaView: NSView {
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }
}

// ============================================================
// MARK: - 横向滚动桥接器
//
// SwiftUI 的 ScrollView(.horizontal) 在 NSPanel 中对 trackpad 横向滑动
// 支持不稳定：NSHostingView 不总是把 scrollWheel 事件转发给内部的
// NSScrollView。这里用 app 级 scrollWheel monitor 拦截事件，手动写
// NSScrollView 的横向 clip bounds。纵向滚轮也一并转成横向（与
// EditorFilmstripWheelBridge 一致），让普通鼠标也能左右翻卡片。
// ============================================================

private struct ClipboardHistoryScrollBridge: NSViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.view = nsView
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator {
        weak var view: NSView?
        private var monitor: Any?

        /// 普通鼠标滚轮 delta 很小，放大到可感知的横向距离；
        /// trackpad 有精确 delta，保持系统原始速度。
        private let mouseWheelMultiplier: CGFloat = 18

        func attach(to view: NSView) {
            self.view = view
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                MainActor.assumeIsolated { self?.handle(event) ?? event }
            }
        }

        func detach() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            view = nil
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
            guard let view, let window = view.window, event.window === window else { return event }
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard modifiers.isEmpty else { return event }

            let deltaX = event.scrollingDeltaX
            let deltaY = event.scrollingDeltaY
            // 横向为主（trackpad 横滑）或纵向为主（鼠标滚轮 / trackpad 纵滑）都转横向
            guard (abs(deltaX) > abs(deltaY) && deltaX != 0)
                || (abs(deltaY) > abs(deltaX) && deltaY != 0),
                let scrollView = findHorizontalScrollView(in: window.contentView),
                let documentView = scrollView.documentView
            else { return event }

            // 连续选择模式左侧还有一个纵向队列。只拦截鼠标位于右侧横向
            // 卡片流内的滚轮事件，避免左侧队列被错误地带着横向滚动。
            let pointInScrollView = scrollView.convert(event.locationInWindow, from: nil)
            guard scrollView.bounds.contains(pointInScrollView) else { return event }

            let clipView = scrollView.contentView
            let delta = abs(deltaX) > abs(deltaY) ? deltaX : deltaY
            let distance = delta * (event.hasPreciseScrollingDeltas ? 1 : mouseWheelMultiplier)
            let maximum = max(0, documentView.bounds.width - clipView.bounds.width)
            let destination = min(max(0, clipView.bounds.origin.x - distance), maximum)
            guard destination != clipView.bounds.origin.x else { return event }

            clipView.scroll(to: CGPoint(x: destination, y: clipView.bounds.origin.y))
            scrollView.reflectScrolledClipView(clipView)
            return nil
        }

        /// 从窗口 contentView 递归找第一个有横向 overflow 的 NSScrollView。
        private func findHorizontalScrollView(in root: NSView?) -> NSScrollView? {
            guard let root else { return nil }
            for child in root.subviews {
                if let scrollView = child as? NSScrollView,
                   hasHorizontalOverflow(scrollView) {
                    return scrollView
                }
                if let nested = findHorizontalScrollView(in: child) { return nested }
            }
            return nil
        }

        private func hasHorizontalOverflow(_ scrollView: NSScrollView) -> Bool {
            guard let documentView = scrollView.documentView else { return false }
            return documentView.bounds.width > scrollView.contentView.bounds.width + 1
        }
    }
}

// ============================================================
// MARK: - 剪贴板历史 SwiftUI 视图
//
// 顶部模式栏 + 中间内容区 + 底部搜索/动作栏。
// ============================================================

struct ClipboardHistoryView: View {

    @ObservedObject var viewModel: ClipboardHistoryViewModel
    @ObservedObject var commands: ClipboardHistoryPanelCommands
    let store: ClipboardHistoryStore
    @StateObject private var thumbnailPreheater = ViewportThumbnailPreheater()

    @FocusState private var searchFocused: Bool
    @State private var isPinned = false
    @State private var isScrolling = false
    @State private var isLiveResizing = false
    @State private var renameItem: ClipboardHistoryItem?
    @State private var renameDraft = ClipboardCardRenameDraft()
    @State private var capsuleRenameID: Int64?
    @State private var capsuleRenameText = ""

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            cardFlow
                .frame(maxHeight: .infinity)
            Divider()
            bottomBar
        }
        .frame(width: 1100, height: 320)
        .background(.regularMaterial)
        .task(id: viewModel.filteredItems
            .filter { $0.kind == .image }
            .map { "\($0.viewportIdentity)#\($0.contentHash)" }
        ) {
            thumbnailPreheater.configure(
                entries: viewModel.filteredItems.compactMap { item in
                    guard item.kind == .image,
                          let url = store.content(of: item).assetURL
                    else { return nil }
                    return ViewportThumbnailEntry(
                        identity: item.viewportIdentity,
                        key: item.thumbnailCacheKey,
                        url: url
                    )
                },
                columnCount: 1
            )
        }
        .onDisappear {
            thumbnailPreheater.reset()
            commands.setRenaming(false)
        }
        .onChange(of: commands.renameGeneration) { _, _ in
            beginRenamingSelectedItem()
        }
    }

    // MARK: 顶部栏

    private var topBar: some View {
        ZStack {
            HStack(spacing: DS.s3) {
                workspaceModePicker

                Spacer()

                if viewModel.workspaceMode == .history {
                    Button {
                        viewModel.setContinuousSelectionEnabled(!viewModel.isContinuousSelectionEnabled)
                    } label: {
                        Image(systemName: viewModel.isContinuousSelectionEnabled
                            ? "rectangle.stack.fill"
                            : "rectangle.stack.badge.plus")
                            .font(.system(size: DS.font12, weight: .medium))
                            .foregroundStyle(viewModel.isContinuousSelectionEnabled ? DS.accent : .secondary)
                            .frame(width: 26, height: 24)
                            .background(
                                viewModel.isContinuousSelectionEnabled
                                    ? DS.accent.opacity(0.13)
                                    : Color.clear,
                                in: RoundedRectangle(cornerRadius: DS.radiusSmall)
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(viewModel.editingCapsuleID != nil)
                    .help(viewModel.editingCapsuleID == nil
                        ? "连续选择：跨搜索建立粘贴队列"
                        : "完成或取消胶囊顺序编辑后可切换模式")
                    .accessibilityLabel("连续选择")
                }

                Button {
                    isPinned.toggle()
                    ClipboardHistoryCoordinator.shared.isPinned = isPinned
                } label: {
                    Image(systemName: isPinned ? "pin.fill" : "pin")
                        .font(.system(size: DS.font13))
                        .foregroundStyle(isPinned ? AnyShapeStyle(DS.accent) : AnyShapeStyle(.tertiary))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .help(isPinned ? "取消钉住" : "钉住面板")

                Text(currentCountLabel)
                    .font(.system(size: DS.font11))
                    .foregroundStyle(.tertiary)
            }

            if let feedback = viewModel.pasteFeedback {
                Text(feedback)
                    .font(.system(size: DS.font11))
                    .foregroundStyle(feedback.contains("无法") ? .red : .secondary)
                    .lineLimit(1)
                    .frame(maxWidth: 360)
                    .allowsHitTesting(false)
            }
        }
        .padding(.horizontal, DS.s4)
        .padding(.vertical, DS.s2)
        .background(WindowDragArea())
    }

    private var workspaceModePicker: some View {
        HStack(spacing: 0) {
            ForEach(ClipboardWorkspaceMode.allCases) { mode in
                Button {
                    viewModel.workspaceMode = mode
                } label: {
                    Image(systemName: mode.systemImage)
                        .font(.system(size: DS.font12, weight: .medium))
                        .frame(width: 28, height: 22)
                        .foregroundStyle(viewModel.workspaceMode == mode ? DS.accent : .secondary)
                        .background(
                            viewModel.workspaceMode == mode ? DS.accent.opacity(0.14) : .clear,
                            in: RoundedRectangle(cornerRadius: DS.radiusSmall)
                        )
                }
                .buttonStyle(.plain)
                .disabled(viewModel.editingCapsuleID != nil && mode != .history)
                .help(mode.title)
                .accessibilityLabel(mode.title)
            }
        }
        .padding(2)
        .background(DS.iconPlaceholderFill, in: RoundedRectangle(cornerRadius: DS.radiusSmall))
    }

    // MARK: 横向卡片流

    @ViewBuilder
    private var cardFlow: some View {
        switch viewModel.workspaceMode {
        case .history:
            historyCardFlow
        case .threads:
            threadFlow
        case .capsules:
            capsuleFlow
        }
    }

    @ViewBuilder
    private var historyCardFlow: some View {
        let visible = viewModel.filteredItems
        if viewModel.isContinuousSelectionEnabled {
            HStack(spacing: 0) {
                pasteQueueRail
                    .frame(width: 220)

                Divider()

                candidateArea(visible)
            }
        } else {
            candidateArea(visible)
        }
    }

    private var threadFlow: some View {
        Group {
            if viewModel.threads.isEmpty {
                workspaceEmptyState(
                    icon: "point.3.connected.trianglepath.dotted",
                    title: "还没有可识别的线程",
                    detail: "短时间内复制的相关内容会自动聚合在这里"
                )
            } else {
                ScrollView(.horizontal) {
                    LazyHStack(spacing: DS.s3) {
                        ForEach(viewModel.threads) { thread in
                            threadCard(thread)
                        }
                    }
                    .padding(.horizontal, DS.s4)
                    .padding(.vertical, DS.s3)
                }
                .scrollIndicators(.hidden)
                .background(ClipboardHistoryScrollBridge())
            }
        }
    }

    private var capsuleFlow: some View {
        Group {
            if viewModel.filteredCapsules.isEmpty {
                workspaceEmptyState(
                    icon: viewModel.capsuleQuery.isEmpty ? "shippingbox" : "magnifyingglass",
                    title: viewModel.capsuleQuery.isEmpty ? "还没有上下文胶囊" : "没有匹配的胶囊",
                    detail: viewModel.capsuleQuery.isEmpty
                        ? "连续选择几张卡片，然后从底部保存为胶囊"
                        : "换一个胶囊名称、内容或来源关键词试试"
                )
            } else {
                ScrollView(.horizontal) {
                    LazyHStack(spacing: DS.s3) {
                        ForEach(viewModel.filteredCapsules) { snapshot in
                            capsuleCard(snapshot)
                        }
                    }
                    .padding(.horizontal, DS.s4)
                    .padding(.vertical, DS.s3)
                }
                .scrollIndicators(.hidden)
                .background(ClipboardHistoryScrollBridge())
            }
        }
    }

    private var bottomBar: some View {
        ZStack {
            bottomCenteredSearch

            HStack(spacing: DS.s3) {
                if viewModel.workspaceMode == .history {
                    ClipboardFilterBar(
                        viewModel: viewModel,
                        showsFilters: true,
                        showsSearch: false,
                        usesIconFilters: true
                    )
                }

                Spacer()

                bottomTrailingActions
            }
        }
        .padding(.horizontal, DS.s4)
        .padding(.vertical, DS.s2)
        .background(.bar)
    }

    @ViewBuilder
    private var bottomCenteredSearch: some View {
        if viewModel.workspaceMode != .capsules {
            ClipboardFilterBar(
                viewModel: viewModel,
                searchWidth: 280,
                showsFilters: false,
                showsSearch: true
            )
        } else {
            HStack(spacing: DS.s1) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: DS.font12))
                    .foregroundStyle(.tertiary)
                TextField("搜索胶囊、内容或来源", text: $viewModel.capsuleQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: DS.font13))
                    .frame(width: 280)
            }
            .padding(.horizontal, DS.s2)
            .padding(.vertical, DS.s1)
            .background(DS.iconPlaceholderFill, in: RoundedRectangle(cornerRadius: DS.radiusSmall))
        }
    }

    @ViewBuilder
    private var bottomTrailingActions: some View {
        if let progress = viewModel.activeCapsulePaste {
            Button {
                viewModel.continueCapsulePaste()
            } label: {
                HStack(spacing: DS.s1) {
                    Image(systemName: "arrow.turn.down.left")
                    Text("\(progress.nextIndex + 1)/\(progress.items.count)")
                        .font(.system(size: DS.font10, weight: .semibold))
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .help(progress.progressLabel)
            .accessibilityLabel(progress.progressLabel)

            Button {
                viewModel.cancelCapsulePaste()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .help("结束逐项粘贴")
            .accessibilityLabel("结束逐项粘贴")
        } else if let editingName = viewModel.editingCapsuleName {
            Label(editingName, systemImage: "arrow.up.arrow.down")
                .font(.system(size: DS.font11, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: 140)

            Button {
                viewModel.cancelCapsuleEditing()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("取消编辑顺序")
            .accessibilityLabel("取消编辑顺序")

            Button {
                viewModel.saveCapsuleEditing()
            } label: {
                Image(systemName: "checkmark")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(viewModel.selectedCount == 0)
            .help("保存顺序")
            .accessibilityLabel("保存顺序")
        } else if viewModel.selectedCount > 0 {
            Label("\(viewModel.selectedCount)", systemImage: "checkmark.circle.fill")
                .font(.system(size: DS.font11, weight: .medium))
                .foregroundStyle(.secondary)
                .help("已选 \(viewModel.selectedCount) 项")

            Button {
                viewModel.createCapsuleFromQueue()
            } label: {
                Image(systemName: "shippingbox.and.arrow.backward")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("存为胶囊")
            .accessibilityLabel("存为胶囊")

            Button {
                viewModel.pasteSelected()
            } label: {
                Image(systemName: ClipboardHistoryCoordinator.shared.supportsDirectPaste
                    ? "arrow.turn.down.left"
                    : "doc.on.doc")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .help(ClipboardHistoryCoordinator.shared.supportsDirectPaste ? "粘贴" : "复制并返回")
            .accessibilityLabel(ClipboardHistoryCoordinator.shared.supportsDirectPaste ? "粘贴" : "复制并返回")
        }
    }

    private var currentCountLabel: String {
        switch viewModel.workspaceMode {
        case .history: return "\(viewModel.filteredItems.count) 项"
        case .threads: return "\(viewModel.threads.count) 条线程"
        case .capsules: return "\(viewModel.filteredCapsules.count) 个胶囊"
        }
    }

    private func threadContextLabel(_ thread: ClipboardThread) -> String {
        let source = thread.sourceApps.prefix(2).joined(separator: " · ")
        let duration = max(0, Int(thread.endedAt.timeIntervalSince(thread.startedAt)))
        let durationText: String
        if duration < 60 {
            durationText = "\(duration) 秒"
        } else {
            durationText = "\(max(1, duration / 60)) 分钟"
        }
        return source.isEmpty ? "跨度 \(durationText)" : "\(source) · \(durationText)"
    }

    private func workspaceEmptyState(icon: String, title: String, detail: String) -> some View {
        VStack(spacing: DS.s2) {
            Image(systemName: icon)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.system(size: DS.font13, weight: .semibold))
            Text(detail)
                .font(.system(size: DS.font11))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func threadCard(_ thread: ClipboardThread) -> some View {
        VStack(alignment: .leading, spacing: DS.s2) {
            HStack(spacing: DS.s2) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .foregroundStyle(DS.accent)
                Text(thread.title)
                    .font(.system(size: DS.font13, weight: .semibold))
                    .lineLimit(1)
                Spacer()
                Text("\(thread.items.count) 项")
                    .font(.system(size: DS.font11, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: DS.s1) {
                ForEach(Array(thread.items.prefix(3).enumerated()), id: \.offset) { index, item in
                    HStack(spacing: DS.s2) {
                        Text("\(index + 1)")
                            .font(.system(size: DS.font10, weight: .semibold))
                            .foregroundStyle(DS.accent)
                            .frame(width: 14)
                        Text(item.displayName)
                            .font(.system(size: DS.font11))
                            .lineLimit(1)
                    }
                }
                if thread.items.count > 3 {
                    Text("还有 \(thread.items.count - 3) 项")
                        .font(.system(size: DS.font11))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)

            HStack(spacing: DS.s2) {
                Text(threadContextLabel(thread))
                    .font(.system(size: DS.font10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Spacer()
                Text(ClipboardCardPresentation.relativeTime(for: thread.endedAt))
                    .font(.system(size: DS.font10))
                    .foregroundStyle(.tertiary)
            }

            HStack(spacing: DS.s2) {
                Button {
                    viewModel.loadPasteQueue(Array(thread.items.reversed()))
                } label: {
                    Image(systemName: "list.number")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("检查粘贴顺序")
                .accessibilityLabel("检查粘贴顺序")

                Button {
                    viewModel.createCapsule(from: thread)
                } label: {
                    Image(systemName: "shippingbox.and.arrow.backward")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .help("存为胶囊")
                .accessibilityLabel("存为胶囊")
            }
        }
        .padding(DS.s3)
        .frame(width: 270, height: ClipboardCardMetrics.popupHeight, alignment: .topLeading)
        .background(DS.panelFill(.resting), in: RoundedRectangle(
            cornerRadius: DS.radiusCard,
            style: .continuous
        ))
        .overlay {
            RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 1)
        }
    }

    private func capsuleCard(_ snapshot: ClipboardCapsuleSnapshot) -> some View {
        VStack(alignment: .leading, spacing: DS.s2) {
            HStack(spacing: DS.s2) {
                Image(systemName: snapshot.capsule.isPinned ? "shippingbox.fill" : "shippingbox")
                    .foregroundStyle(snapshot.capsule.isPinned ? DS.accent : .secondary)

                if capsuleRenameID == snapshot.id {
                    TextField("胶囊名称", text: $capsuleRenameText)
                        .textFieldStyle(.plain)
                        .font(.system(size: DS.font13, weight: .semibold))
                        .onSubmit { commitCapsuleRename(snapshot) }
                } else {
                    Text(snapshot.capsule.name)
                        .font(.system(size: DS.font13, weight: .semibold))
                        .lineLimit(1)
                        .onTapGesture(count: 2) { beginCapsuleRename(snapshot) }
                }

                Spacer()

                Button {
                    beginCapsuleRename(snapshot)
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: DS.font11))
                }
                .buttonStyle(.plain)
                .help("修改胶囊名称")
            }

            VStack(alignment: .leading, spacing: DS.s1) {
                ForEach(Array(snapshot.items.prefix(3).enumerated()), id: \.offset) { index, item in
                    HStack(spacing: DS.s2) {
                        Text("\(index + 1)")
                            .font(.system(size: DS.font10, weight: .semibold))
                            .foregroundStyle(DS.accent)
                            .frame(width: 14)
                        Text(item.displayName)
                            .font(.system(size: DS.font11))
                            .lineLimit(1)
                    }
                }
                if snapshot.items.count > 3 {
                    Text("还有 \(snapshot.items.count - 3) 项")
                        .font(.system(size: DS.font11))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)

            HStack {
                Text("\(snapshot.items.count) 项 · 保留选择顺序")
                    .font(.system(size: DS.font10))
                    .foregroundStyle(.tertiary)
                Spacer()
            }

            HStack(spacing: DS.s2) {
                let pasteLabel = Set(snapshot.items.map(\.kind)).count > 1 ? "逐项粘贴" : "粘贴全部"
                Button {
                    viewModel.pasteCapsule(snapshot)
                } label: {
                    Image(systemName: "arrow.turn.down.left")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .help(pasteLabel)
                .accessibilityLabel(pasteLabel)

                Button {
                    viewModel.beginEditingCapsule(snapshot)
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("编辑顺序")
                .accessibilityLabel("编辑顺序")
            }
        }
        .padding(DS.s3)
        .frame(width: 270, height: ClipboardCardMetrics.popupHeight, alignment: .topLeading)
        .background(DS.panelFill(.resting), in: RoundedRectangle(
            cornerRadius: DS.radiusCard,
            style: .continuous
        ))
        .overlay {
            RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous)
                .strokeBorder(
                    snapshot.capsule.isPinned
                        ? DS.accent.opacity(0.7)
                        : Color(nsColor: .separatorColor).opacity(0.5),
                    lineWidth: 1
                )
        }
        .contextMenu {
            Button("粘贴") { viewModel.pasteCapsule(snapshot) }
            Button("修改名称") { beginCapsuleRename(snapshot) }
            Button("编辑顺序") { viewModel.beginEditingCapsule(snapshot) }
            Button(snapshot.capsule.isPinned ? "取消固定" : "固定") {
                viewModel.toggleCapsulePin(snapshot)
            }
            Divider()
            Button("删除胶囊", role: .destructive) { viewModel.deleteCapsule(snapshot) }
        }
    }

    private func beginCapsuleRename(_ snapshot: ClipboardCapsuleSnapshot) {
        capsuleRenameText = snapshot.capsule.name
        capsuleRenameID = snapshot.id
    }

    private func commitCapsuleRename(_ snapshot: ClipboardCapsuleSnapshot) {
        guard capsuleRenameID == snapshot.id else { return }
        let name = capsuleRenameText
        capsuleRenameID = nil
        capsuleRenameText = ""
        viewModel.renameCapsule(name, snapshot: snapshot)
    }

    @ViewBuilder
    private func candidateArea(_ visible: [ClipboardHistoryItem]) -> some View {
        if visible.isEmpty {
            emptyState
        } else {
            RecyclingCardCollectionView(
                sections: [RecyclingCardSection(
                    id: "clipboard-panel",
                    title: "",
                    items: visible
                )],
                columnCount: 1,
                fixedItemWidth: ClipboardCardMetrics.popupWidth,
                itemHeight: ClipboardCardMetrics.popupHeight,
                interitemSpacing: DS.s3,
                lineSpacing: DS.s3,
                contentInsets: NSEdgeInsets(
                    top: DS.s3,
                    left: DS.s4,
                    bottom: DS.s3,
                    right: DS.s4
                ),
                headerHeight: 0,
                pinsHeaders: false,
                scrollAxis: .horizontal,
                handlesSelection: true,
                selectionHitTest: { _, point, size in
                    ClipboardCardInteractionZones.selectsCard(at: point, in: size)
                },
                scrollTarget: viewModel.selectedItemID,
                card: { item in popupCard(for: item) },
                header: { _ in EmptyView() },
                onDisplay: { item in
                    viewModel.loadMoreIfNeeded(reaching: item)
                    guard item.kind == .image else { return }
                    thumbnailPreheater.mounted(item.viewportIdentity)
                },
                onEndDisplay: { item in
                    guard item.kind == .image else { return }
                    thumbnailPreheater.unmounted(item.viewportIdentity)
                },
                onSelect: { item, modifiers in
                    commands.prepareForCardInteraction()
                    viewModel.select(
                        item,
                        extending: modifiers.contains(.command),
                        continuingQueue: viewModel.isContinuousSelectionEnabled
                    )
                },
                onDoubleClick: { item in viewModel.paste(item) }
            )
            .modifier(GalleryInteractionTracker(
                isScrolling: $isScrolling,
                isLiveResizing: $isLiveResizing
            ))
            .environment(\.galleryIsScrolling, isScrolling)
            .environment(\.galleryDefersThumbnailLoading, isLiveResizing)
            .background(ClipboardHistoryScrollBridge())
        }
    }

    private var pasteQueueRail: some View {
        VStack(spacing: DS.s2) {
            HStack {
                Image(systemName: "list.number")
                    .font(.system(size: DS.font12, weight: .semibold))
                    .help("粘贴队列")
                    .accessibilityLabel("粘贴队列")
                Spacer()
                Text("\(viewModel.selectedCount)")
                    .font(.system(size: DS.font11, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            if viewModel.pasteQueueItems.isEmpty {
                Text("在右侧点击卡片加入队列")
                    .font(.system(size: DS.font11))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: DS.s1) {
                        ForEach(Array(viewModel.pasteQueueItems.enumerated()), id: \.offset) { index, item in
                            pasteQueueRow(item, ordinal: index + 1)
                        }
                    }
                }
            }

            HStack(spacing: DS.s2) {
                Button {
                    viewModel.clearPasteQueue()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(viewModel.pasteQueueItems.isEmpty)
                .help("清空粘贴队列")
                .accessibilityLabel("清空粘贴队列")

                Button {
                    viewModel.pasteSelected()
                } label: {
                    Image(systemName: ClipboardHistoryCoordinator.shared.supportsDirectPaste
                        ? "arrow.turn.down.left"
                        : "doc.on.doc")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(viewModel.pasteQueueItems.isEmpty)
                .help(ClipboardHistoryCoordinator.shared.supportsDirectPaste ? "粘贴" : "复制并返回")
                .accessibilityLabel(ClipboardHistoryCoordinator.shared.supportsDirectPaste ? "粘贴" : "复制并返回")
            }
        }
        .padding(DS.s3)
        .background(DS.panelFill(.resting))
    }

    private func pasteQueueRow(_ item: ClipboardHistoryItem, ordinal: Int) -> some View {
        HStack(spacing: DS.s2) {
            Text("\(ordinal)")
                .font(.system(size: DS.font11, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(DS.accent, in: Circle())

            Image(systemName: queueIcon(for: item.kind))
                .font(.system(size: DS.font12))
                .foregroundStyle(.secondary)
                .frame(width: 16)

            Text(item.displayName)
                .font(.system(size: DS.font11))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 0) {
                Button {
                    viewModel.movePasteQueueItem(item, by: -1)
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 8, weight: .bold))
                }
                .buttonStyle(.plain)
                .disabled(ordinal == 1)
                .help("向前移动")

                Button {
                    viewModel.movePasteQueueItem(item, by: 1)
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                }
                .buttonStyle(.plain)
                .disabled(ordinal == viewModel.selectedCount)
                .help("向后移动")
            }

            Button {
                viewModel.removeFromPasteQueue(item)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: DS.font11, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("从粘贴队列移除")
        }
        .padding(.horizontal, DS.s2)
        .padding(.vertical, DS.s1)
        .background(DS.panelFill(.overlay), in: RoundedRectangle(
            cornerRadius: DS.radiusSmall,
            style: .continuous
        ))
    }

    private func queueIcon(for kind: ClipboardHistoryKind) -> String {
        switch kind {
        case .text: return "text.alignleft"
        case .image: return "photo"
        case .file: return "doc"
        }
    }

    private func popupCard(for item: ClipboardHistoryItem) -> some View {
        let ordinal = viewModel.selectionOrdinal(for: item)
        return RecyclingCardHoverReader { nativeHover in
            ClipboardHistoryCard(
                item: item,
                isSelected: ordinal != nil,
                selectionOrdinal: viewModel.isContinuousSelectionEnabled ? ordinal : nil,
                isHovering: nativeHover && !isScrolling,
                store: store,
                isRenaming: renameItem?.viewportIdentity == item.viewportIdentity,
                renameText: renameDraft.text,
                onRenameTextChange: { renameDraft.text = $0 },
                onBeginRename: { beginRenaming(item) },
                onCommitRename: { commitRenaming(item, title: $0) },
                onCancelRename: { cancelRenaming(item) }
            )
            .equatable()
        }
        .onDrag {
            viewModel.dragProvider(for: item)
        }
        .contextMenu {
            Button("粘贴") { viewModel.paste(item) }
                .keyboardShortcut(.return, modifiers: [])
            if item.kind == .text {
                Button("以纯文本粘贴") { viewModel.pasteAsPlainText(item) }
                    .keyboardShortcut(.return, modifiers: [.shift])
            }
            Button("复制") { viewModel.copyBack(item) }
                .keyboardShortcut("c", modifiers: [.command])
            Button("修改名称") { beginRenaming(item) }
                .keyboardShortcut("r", modifiers: [.command])
            Button(item.pinned ? "取消固定" : "固定") { viewModel.togglePin(item) }
            Divider()
            Button("删除", role: .destructive) { viewModel.delete(item) }
                .keyboardShortcut(.delete, modifiers: [])
        }
    }

    private func beginRenamingSelectedItem() {
        let visible = viewModel.filteredItems
        guard visible.indices.contains(viewModel.selectedIndex) else { return }
        beginRenaming(visible[viewModel.selectedIndex])
    }

    private func beginRenaming(_ item: ClipboardHistoryItem) {
        if let activeItem = renameItem,
           activeItem.viewportIdentity != item.viewportIdentity {
            commitRenaming(activeItem)
        }
        renameDraft.text = item.title ?? ""
        renameItem = item
        commands.setRenaming(true)
    }

    private func commitRenaming(_ item: ClipboardHistoryItem, title: String? = nil) {
        guard renameItem?.viewportIdentity == item.viewportIdentity else { return }
        if let title { renameDraft.text = title }
        let committedTitle = renameDraft.text
        renameItem = nil
        renameDraft.text = ""
        commands.setRenaming(false)
        viewModel.rename(committedTitle, for: item)
    }

    private func cancelRenaming(_ item: ClipboardHistoryItem) {
        guard renameItem?.viewportIdentity == item.viewportIdentity else { return }
        renameItem = nil
        renameDraft.text = ""
        commands.setRenaming(false)
    }

    private var emptyState: some View {
        VStack(spacing: DS.s2) {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: DS.font20))
                .foregroundStyle(.tertiary)
            Text(viewModel.query.isEmpty ? "暂无剪贴板历史" : "没有匹配的结果")
                .font(.system(size: DS.font12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
