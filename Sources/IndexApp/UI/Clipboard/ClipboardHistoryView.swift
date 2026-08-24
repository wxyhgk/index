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

// MARK: - 图片 hover 大图预览
//
// 独立 NSWindow 浮出，可以超出面板边界。
// 鼠标悬停 400ms 后显示，离开即消失。

@MainActor
final class ImagePreviewController {
    static let shared = ImagePreviewController()

    private var window: NSWindow?
    private var imageView: NSImageView?
    private var showTask: Task<Void, Never>?

    func scheduleShow(image: NSImage, screenPoint: NSPoint) {
        showTask?.cancel()
        showTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            self?.show(image: image, near: screenPoint)
        }
    }

    /// 立即显示（空格键触发，不走延迟）。
    func showNow(image: NSImage, screenPoint: NSPoint) {
        showTask?.cancel()
        showTask = nil
        show(image: image, near: screenPoint)
    }

    func cancel() {
        showTask?.cancel()
        showTask = nil
        window?.orderOut(nil)
    }

    private func show(image: NSImage, near point: NSPoint) {
        let maxDim: CGFloat = 420
        let scale = min(1, maxDim / max(image.size.width, image.size.height))
        let w = image.size.width * scale
        let h = image.size.height * scale

        if window == nil {
            let win = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            win.level = .floating
            win.isOpaque = false
            win.backgroundColor = .clear
            win.hasShadow = true
            win.ignoresMouseEvents = true
            win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

            let iv = NSImageView(frame: NSRect(x: 0, y: 0, width: w, height: h))
            iv.imageScaling = .scaleProportionallyUpOrDown
            iv.wantsLayer = true
            iv.layer?.cornerRadius = 10
            iv.layer?.masksToBounds = true
            iv.layer?.borderWidth = 1
            iv.layer?.borderColor = NSColor.separatorColor.cgColor
            win.contentView = iv
            window = win
            imageView = iv
        }

        window?.setContentSize(NSSize(width: w, height: h))
        imageView?.image = image

        // 位置：鼠标上方居中
        let x = point.x - w / 2
        let y = point.y + 8
        window?.setFrameOrigin(NSPoint(x: x, y: y))
        window?.orderFront(nil)
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
// 顶部栏（类型过滤 + 搜索 + 计数）+ 横向卡片流。
// ============================================================

struct ClipboardHistoryView: View {

    @ObservedObject var viewModel: ClipboardHistoryViewModel
    let store: ClipboardHistoryStore
    @StateObject private var thumbnailPreheater = ViewportThumbnailPreheater()

    @FocusState private var searchFocused: Bool
    @State private var isPinned = false

    var body: some View {
        VStack(spacing: 0) {
            topBar
            cardFlow
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
        .onDisappear { thumbnailPreheater.reset() }
    }

    // MARK: 顶部栏

    private var topBar: some View {
        HStack(spacing: DS.s3) {
            ClipboardFilterBar(viewModel: viewModel, searchWidth: 160)

            Button {
                viewModel.setContinuousSelectionEnabled(!viewModel.isContinuousSelectionEnabled)
            } label: {
                Label(
                    "连续选择",
                    systemImage: viewModel.isContinuousSelectionEnabled
                        ? "rectangle.stack.fill"
                        : "rectangle.stack.badge.plus"
                )
                .font(.system(size: DS.font11, weight: .medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(viewModel.isContinuousSelectionEnabled ? DS.accent : nil)
            .help(viewModel.isContinuousSelectionEnabled
                ? "已开启：点击搜索结果会加入左侧固定队列"
                : "开启后可跨搜索连续选择")

            Spacer()

            if let feedback = viewModel.pasteFeedback {
                Text(feedback)
                    .font(.system(size: DS.font11))
                    .foregroundStyle(.red)
                    .lineLimit(1)
            } else if viewModel.isContinuousSelectionEnabled {
                Text("左侧队列固定，右侧可继续搜索")
                    .font(.system(size: DS.font11))
                    .foregroundStyle(.tertiary)
            }

            // 钉住按钮
            Button {
                isPinned.toggle()
                ClipboardHistoryCoordinator.shared.isPinned = isPinned
            } label: {
                Image(systemName: isPinned ? "pin.fill" : "pin")
                    .font(.system(size: DS.font13))
                    .foregroundStyle(isPinned ? AnyShapeStyle(DS.accent) : AnyShapeStyle(.tertiary))
            }
            .buttonStyle(.plain)
            .help(isPinned ? "取消钉住" : "钉住面板")

            // 计数
            Text("\(viewModel.filteredItems.count) 项")
                .font(.system(size: DS.font11))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, DS.s4)
        .padding(.vertical, DS.s3)
        .background(WindowDragArea())
    }

    // MARK: 横向卡片流

    @ViewBuilder
    private var cardFlow: some View {
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
                fixedItemWidth: 190,
                itemHeight: 190,
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
                scrollTarget: viewModel.selectedItemID,
                card: { item in popupCard(for: item) },
                header: { _ in EmptyView() },
                onDisplay: { item in
                    guard item.kind == .image else { return }
                    thumbnailPreheater.mounted(item.viewportIdentity)
                },
                onEndDisplay: { item in
                    guard item.kind == .image else { return }
                    thumbnailPreheater.unmounted(item.viewportIdentity)
                },
                onSelect: { item, modifiers in
                    viewModel.select(
                        item,
                        extending: modifiers.contains(.command),
                        continuingQueue: viewModel.isContinuousSelectionEnabled
                    )
                },
                onDoubleClick: { item in viewModel.paste(item) }
            )
            .background(ClipboardHistoryScrollBridge())
        }
    }

    private var pasteQueueRail: some View {
        VStack(spacing: DS.s2) {
            HStack {
                Label("粘贴队列", systemImage: "list.number")
                    .font(.system(size: DS.font12, weight: .semibold))
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
                Button("清空") {
                    viewModel.clearPasteQueue()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(viewModel.pasteQueueItems.isEmpty)

                Button("粘贴") {
                    viewModel.pasteSelected()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(viewModel.pasteQueueItems.isEmpty)
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
        return ClipboardHistoryCard(
            item: item,
            isSelected: ordinal != nil,
            selectionOrdinal: viewModel.isContinuousSelectionEnabled ? ordinal : nil,
            store: store
        )
        .equatable()
        .onDrag {
            viewModel.dragProvider(for: item)
        }
        .contextMenu {
            Button("复制") { viewModel.copyBack(item) }
            Button(item.pinned ? "取消固定" : "固定") { viewModel.togglePin(item) }
            Divider()
            Button("删除", role: .destructive) { viewModel.delete(item) }
        }
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
