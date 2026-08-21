import SwiftUI
import AppKit

enum EditorFilmstripLayout {
    static let cellSize = CGSize(width: 96, height: 56)

    /// 图片只负责在固定点击外框内等比展示，不能再用自身宽高比决定按钮几何。
    static func fittedImageSize(pixelWidth: Int, pixelHeight: Int) -> CGSize {
        guard pixelWidth > 0, pixelHeight > 0 else { return .zero }
        let scale = min(
            cellSize.width / CGFloat(pixelWidth),
            cellSize.height / CGFloat(pixelHeight)
        )
        return CGSize(
            width: CGFloat(pixelWidth) * scale,
            height: CGFloat(pixelHeight) * scale
        )
    }
}

enum EditorFilmstripWheel {
    /// 普通鼠标滚轮每格的 AppKit delta 很小，转换成可感知的横向距离；
    /// 触控板有精确 delta，保持系统原始速度。
    static let mouseWheelMultiplier: CGFloat = 18

    static func shouldConvert(deltaX: CGFloat, deltaY: CGFloat) -> Bool {
        abs(deltaY) > abs(deltaX) && deltaY != 0
    }

    static func destinationX(
        originX: CGFloat,
        documentWidth: CGFloat,
        viewportWidth: CGFloat,
        deltaY: CGFloat,
        hasPreciseDeltas: Bool
    ) -> CGFloat {
        let distance = deltaY * (hasPreciseDeltas ? 1 : mouseWheelMultiplier)
        let maximum = max(0, documentWidth - viewportWidth)
        return min(max(0, originX - distance), maximum)
    }
}

/// SwiftUI 的横向 ScrollView 对普通鼠标纵向滚轮支持不稳定。
///
/// 这枚零视觉背景只在自己的命中区域里监听滚轮，把“纵向为主”的 delta 写进
/// 对应 NSScrollView 的横向 clip bounds。原生触控板横滑、Shift+滚轮和其它区域的
/// 滚动事件仍交给系统。
private struct EditorFilmstripWheelBridge: NSViewRepresentable {
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
            guard modifiers.isEmpty,
                  EditorFilmstripWheel.shouldConvert(
                    deltaX: event.scrollingDeltaX,
                    deltaY: event.scrollingDeltaY
                  ),
                  let scrollView = enclosingHorizontalScrollView(from: view),
                  let documentView = scrollView.documentView
            else { return event }

            let clipView = scrollView.contentView
            let destination = EditorFilmstripWheel.destinationX(
                originX: clipView.bounds.origin.x,
                documentWidth: documentView.bounds.width,
                viewportWidth: clipView.bounds.width,
                deltaY: event.scrollingDeltaY,
                hasPreciseDeltas: event.hasPreciseScrollingDeltas
            )
            guard destination != clipView.bounds.origin.x else { return event }

            clipView.scroll(to: CGPoint(x: destination, y: clipView.bounds.origin.y))
            scrollView.reflectScrolledClipView(clipView)
            return nil
        }

        /// SwiftUI 可能把 representable 放在 documentView 内，也可能作为 ScrollView
        /// 的布局兄弟。先走 AppKit 的 enclosingScrollView，再在最近祖先的小子树中找
        /// 真正有横向溢出的那一枚，避免误命中编辑器画布的 NSScrollView。
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

/// 编辑器底部的胶片条（Snagit 式）：全库截图缩略图横排，不出编辑器直接换图。
///
/// 数据源是 `ShotStore.allShots()` —— 全库时间倒序，**刻意不跟图库的搜索 / 筛选联动**：
/// 编辑器换图的心智是「库里最近截了什么」，不该被另一个窗口的筛选状态牵着走。
/// 订阅 store 的变更通知刷新，新截图 / 删除都会即时体现。
///
/// 自带顶部 Divider，由稳定的 `EditorModeView` 放在会话化画布之外。
struct EditorFilmstrip: View, Equatable {

    /// 相等性**只看当前编辑的是哪张图**。
    ///
    /// 闭包不参与比较（也没法比）—— `onSelect` 每次都是新实例，
    /// 但它做的事是恒定的「先落库再换图」，与画布上画了什么无关。
    /// 稳定宿主用 `.equatable()` 挂上这条规则之后，标注变更不再惊动胶片条。
    static func == (lhs: EditorFilmstrip, rhs: EditorFilmstrip) -> Bool {
        lhs.currentShotID == rhs.currentShotID
    }

    /// 当前编辑中的 shot ID：高亮 accent 描边；首次打开时自动滚动到可见。
    let currentShotID: Int64?
    /// 点击其它缩略图 → 请求换图。宿主负责先落库再换。
    ///
    /// **闭包让本结构体无法被判定为「没变」**，所以父视图每次重算 body
    /// 都会连带重算这里。真正的解法是不让它出现在会频繁重算的 body 里 ——
    /// 稳定宿主已经把它包进 `EquatableView`（见 `EditorModeView`），
    /// 相等性只看 `currentShotID`：标注怎么画都与胶片条无关。
    let onSelect: (Shot) -> Void

    /// 收起状态跨窗口、跨启动记住 —— 胶片条是屏幕空间的取舍，偏好因人而异。
    @AppStorage("editorFilmstripCollapsed") private var collapsed = false

    @State private var shots: [Shot] = []
    @Environment(\.colorScheme) private var colorScheme

    private let store: ShotStore

    init(currentShotID: Int64?, onSelect: @escaping (Shot) -> Void, store: ShotStore = .shared) {
        self.currentShotID = currentShotID
        self.onSelect = onSelect
        self.store = store
    }

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 0) {
                if collapsed {
                    Text("胶片条（\(shots.count)）")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.leading, DS.s4)
                    Spacer()
                } else {
                    strip
                }
                toggleButton
            }
            .frame(height: collapsed ? 24 : 72)
        }
        .onAppear(perform: refresh)
        // 只订「库存内容变了」，**不订 objectWillChange**。
        //
        // 后者任何写入都会发，包括编辑器自己每隔一秒多的一次修订保存 ——
        // 而保存修订并不改变胶片条的内容（还是同一批截图、同样的顺序），
        // 却会害这里在主线程上重查一次全库。那正是「编辑时点按钮有延迟」的来源。
        //
        // `libraryDidChange` 发在 `reload()` 之后（即库存真的重查过），
        // 所以这里不需要再 `DispatchQueue.main.async` 转一拍去等变更落地。
        .onReceive(store.libraryDidChange) { _ in refresh() }
    }

    // MARK: - 胶片

    private var strip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                // ⚠️ **必须是 Lazy**。普通 `HStack` 会把 `shots` 里的每一张都构建出来
                // （当前上限 300），而本视图带着一个闭包参数 `onSelect` —— 结构体因此
                // 无法被 SwiftUI 判定为「没变」，**父视图 body 一重算它就跟着重算**。
                // 编辑器里每一次标注变更都会重算 body，于是画一笔的每一帧
                // 都在构建几百个缩略图子视图（每个还带一个 `.task`）。
                // 这是「编辑时点按钮有延迟」查到最后的那一层。
                LazyHStack(spacing: DS.s2) {
                    ForEach(shots) { shot in
                        thumbnail(shot)
                    }
                }
                .padding(.horizontal, DS.s3)
                .padding(.vertical, DS.s2)
            }
            .background(EditorFilmstripWheelBridge())
            .onAppear { scrollToCurrent(proxy, animated: false) }
            // 点击的缩略图本来就在视野里，不要为了“居中”把整条内容横向推走。
            // 初次打开编辑器时，shots 从空变为查询结果，下面这条仍会定位当前项。
            .onChange(of: shots) { scrollToCurrent(proxy, animated: false) }
        }
    }

    private func thumbnail(_ shot: Shot) -> some View {
        let isCurrent = shot.id == currentShotID
        let imageSize = EditorFilmstripLayout.fittedImageSize(
            pixelWidth: shot.pixelWidth,
            pixelHeight: shot.pixelHeight
        )
        return Button {
            if !isCurrent { onSelect(shot) }
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: DS.radiusSmall, style: .continuous)
                    .fill(DS.thumbnailBacking(colorScheme))

                CachedImage(url: store.thumbnailURL(for: shot), key: shot.sha256)
                    .frame(width: imageSize.width, height: imageSize.height)
            }
            .frame(
                width: EditorFilmstripLayout.cellSize.width,
                height: EditorFilmstripLayout.cellSize.height
            )
            .clipShape(RoundedRectangle(cornerRadius: DS.radiusSmall, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DS.radiusSmall, style: .continuous)
                    .strokeBorder(
                        isCurrent ? DS.accent : DS.borderDefault,
                        lineWidth: isCurrent ? 2 : 1
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: DS.radiusSmall, style: .continuous))
        }
        .buttonStyle(.plain)
        // ScrollViewReader 的滚动锚点。Int64? 类型与 scrollToCurrent 传入的一致。
        .id(shot.id)
        .help(shot.sourceSummary)
        .accessibilityLabel(shot.primaryDisplayName)
        .accessibilityValue(isCurrent ? "当前正在编辑" : "")
    }

    private func scrollToCurrent(_ proxy: ScrollViewProxy, animated: Bool) {
        guard currentShotID != nil else { return }
        if animated {
            withAnimation(.easeInOut(duration: 0.2)) {
                proxy.scrollTo(currentShotID, anchor: .center)
            }
        } else {
            proxy.scrollTo(currentShotID, anchor: .center)
        }
    }

    // MARK: - 折叠

    private var toggleButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { collapsed.toggle() }
        } label: {
            Image(systemName: collapsed ? "chevron.up" : "chevron.down")
                .font(.caption)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .padding(.trailing, DS.s2)
        .help(collapsed ? "展开胶片条" : "收起胶片条")
    }

    /// 重查全库。
    ///
    /// ⚠️ **这是主线程上的一次 500 行取回 + 全量解码**，不便宜。
    /// 它订阅的是 store 的**全部**变更，而编辑器每保存一次修订就会发一次通知 ——
    /// 于是编辑时每隔一秒多就在主线程上重查一次全库，表现为「点按钮有延迟」。
    ///
    /// 但保存修订并**不改变胶片条的内容**：还是同一批截图、同样的顺序，
    /// 变的只是某一张的缩略图像素（那由 `ThumbnailCache` 的作废机制负责刷新，
    /// 与这里的列表无关）。所以先做一次廉价的对比，**内容没变就不动**——
    /// 不动 `shots` 就不会触发 ForEach 重建，也不会连锁 scrollToCurrent。
    private func refresh() {
        let latest = store.allShots()
        // Shot 是 Equatable，但逐个比对 500 个结构体也不必要：
        // 胶片条只关心「有哪些图、什么顺序」，比 ID 序列就够了。
        guard latest.map(\.id) != shots.map(\.id) else { return }
        shots = latest
    }
}
