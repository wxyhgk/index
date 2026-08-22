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
            // bridge 是 ScrollView 的 .background()（兄弟视图），自身 bounds 不可靠，
            // 改为检查鼠标是否在窗口内容区域内。
            guard let content = window.contentView,
                  content.bounds.contains(content.convert(event.locationInWindow, from: nil))
            else { return event }

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

    @FocusState private var searchFocused: Bool
    @State private var isPinned = false

    var body: some View {
        VStack(spacing: 0) {
            topBar
            cardFlow
        }
        .frame(width: 1100, height: 320)
        .background(.regularMaterial)
    }

    // MARK: 顶部栏

    private var topBar: some View {
        HStack(spacing: DS.s3) {
            ClipboardFilterBar(viewModel: viewModel, searchWidth: 160)

            Spacer()

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
        if visible.isEmpty {
            emptyState
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: DS.s3) {
                    ForEach(Array(visible.enumerated()), id: \.element.id) { index, item in
                        ClipboardHistoryCard(
                            item: item,
                            thumbnail: item.id.flatMap { viewModel.imageThumbnails[$0] },
                            appIcon: item.sourceApp.flatMap { viewModel.appIcons[$0] },
                            isSelected: index == viewModel.selectedIndex
                        )
                        .onTapGesture {
                            if viewModel.selectedIndex == index {
                                // 第二次点同一张卡片：粘贴。
                                viewModel.pasteSelected()
                            } else {
                                // 第一次点：选中。
                                viewModel.selectedIndex = index
                            }
                        }
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
                }
                .padding(.horizontal, DS.s4)
                .padding(.vertical, DS.s3)
            }
            .background(ClipboardHistoryScrollBridge())
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
