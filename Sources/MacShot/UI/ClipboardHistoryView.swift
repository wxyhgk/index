import SwiftUI
import AppKit

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
            let point = view.convert(event.locationInWindow, from: nil)
            guard view.bounds.contains(point) else { return event }

            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard modifiers.isEmpty else { return event }

            let deltaX = event.scrollingDeltaX
            let deltaY = event.scrollingDeltaY
            // 横向为主（trackpad 横滑）或纵向为主（鼠标滚轮 / trackpad 纵滑）都转横向
            guard (abs(deltaX) > abs(deltaY) && deltaX != 0)
                || (abs(deltaY) > abs(deltaX) && deltaY != 0),
                let scrollView = enclosingHorizontalScrollView(from: view),
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

        private func enclosingHorizontalScrollView(from view: NSView) -> NSScrollView? {
            if let scrollView = view.enclosingScrollView,
               hasHorizontalOverflow(scrollView) {
                return scrollView
            }
            var ancestor = view.superview
            while let candidate = ancestor {
                if let scrollView = firstHorizontalScrollView(in: candidate) { return scrollView }
                ancestor = candidate.superview
            }
            return nil
        }

        private func firstHorizontalScrollView(in root: NSView) -> NSScrollView? {
            for child in root.subviews {
                if let scrollView = child as? NSScrollView,
                   hasHorizontalOverflow(scrollView) {
                    return scrollView
                }
                if let nested = firstHorizontalScrollView(in: child) { return nested }
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
            // 类型过滤 tab
            HStack(spacing: DS.s1) {
                filterTab("全部", kind: nil)
                filterTab("文本", kind: .text)
                filterTab("图片", kind: .image)
                filterTab("文件", kind: .file)
            }

            Spacer()

            // 搜索
            HStack(spacing: DS.s1) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: DS.font12))
                    .foregroundStyle(.tertiary)
                TextField("搜索", text: $viewModel.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: DS.font13))
                    .frame(width: 160)
                    .focused($searchFocused)
                    .onChange(of: viewModel.query) { _ in
                        viewModel.searchChanged()
                    }
            }
            .padding(.horizontal, DS.s2)
            .padding(.vertical, DS.s1)
            .background(DS.iconPlaceholderFill, in: RoundedRectangle(cornerRadius: DS.radiusSmall))

            // 计数
            Text("\(viewModel.filteredItems.count) 项")
                .font(.system(size: DS.font11))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, DS.s4)
        .padding(.vertical, DS.s3)
    }

    private func filterTab(_ title: String, kind: ClipboardHistoryKind?) -> some View {
        Button {
            viewModel.setTypeFilter(kind)
        } label: {
            Text(title)
                .font(.system(size: DS.font12, weight: viewModel.typeFilter == kind ? .semibold : .regular))
                .padding(.horizontal, DS.s2)
                .padding(.vertical, DS.s1)
                .background(
                    viewModel.typeFilter == kind
                        ? DS.accent.opacity(0.15)
                        : Color.clear,
                    in: RoundedRectangle(cornerRadius: DS.radiusSmall)
                )
                .foregroundStyle(viewModel.typeFilter == kind ? DS.accent : .secondary)
        }
        .buttonStyle(.plain)
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
                            viewModel.selectedIndex = index
                            viewModel.copyBack(item)
                            ClipboardHistoryCoordinator.shared.togglePanel()
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
