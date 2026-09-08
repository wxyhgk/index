import AppKit
import SwiftUI

private struct RecyclingCardIsHoveredKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// 由 NSCollectionView 复用单元格提供的原生悬停状态。
    /// 不依赖宿主 SwiftUI 根视图的 `.onHover`，因此根视图替换、
    /// cell 复用和悬停按钮出现都不会改变命中区域。
    var recyclingCardIsHovered: Bool {
        get { self[RecyclingCardIsHoveredKey.self] }
        set { self[RecyclingCardIsHoveredKey.self] = newValue }
    }
}

/// 把复用 cell 的原生 hover 变成宿主卡片的显式输入。
/// 不让 `EquatableView` 只因卡片模型没变就跳过环境变化。
struct RecyclingCardHoverReader<Content: View>: View {
    @Environment(\.recyclingCardIsHovered) private var isHovered
    let content: (Bool) -> Content

    init(@ViewBuilder content: @escaping (Bool) -> Content) {
        self.content = content
    }

    var body: some View {
        content(isHovered)
    }
}

/// One lightweight section for AppKit's recycling card grid. The section owns
/// model values only; actual card views are created on demand by NSCollectionView.
struct RecyclingCardSection<Item: Identifiable & Equatable>: Identifiable, Equatable
where Item.ID: Hashable {
    let id: String
    let title: String
    let items: [Item]
}

enum RecyclingCardScrollAxis: Equatable {
    case vertical
    case horizontal
}

/// A macOS-native, cell-recycling card grid that can still host SwiftUI-authored
/// card content. SwiftUI owns product state; AppKit owns scrolling, layout, and
/// the small reusable pool of visible NSCollectionViewItem instances.
struct RecyclingCardCollectionView<
    Item: Identifiable & Equatable,
    Card: View,
    Header: View
>: NSViewRepresentable where Item.ID: Hashable {
    let sections: [RecyclingCardSection<Item>]
    let columnCount: Int
    let fixedItemWidth: CGFloat?
    let itemHeight: CGFloat
    let interitemSpacing: CGFloat
    let lineSpacing: CGFloat
    let contentInsets: NSEdgeInsets
    let headerHeight: CGFloat
    let pinsHeaders: Bool
    var scrollAxis: RecyclingCardScrollAxis = .vertical
    var handlesSelection = false
    var selectionHitTest: (Item, NSPoint, NSSize) -> Bool = { _, _, _ in true }
    let scrollTarget: Item.ID?
    let card: (Item) -> Card
    let header: (RecyclingCardSection<Item>) -> Header
    let onDisplay: (Item) -> Void
    let onEndDisplay: (Item) -> Void
    var onSelect: (Item, NSEvent.ModifierFlags) -> Void = { _, _ in }
    var onDoubleClick: (Item) -> Void = { _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> RecyclingCardHostView {
        let host = RecyclingCardHostView()
        context.coordinator.attach(to: host)
        context.coordinator.apply(parent: self, to: host, isInitial: true)
        return host
    }

    func updateNSView(_ host: RecyclingCardHostView, context: Context) {
        context.coordinator.apply(parent: self, to: host, isInitial: false)
    }

    static func dismantleNSView(_ host: RecyclingCardHostView, coordinator: Coordinator) {
        coordinator.detach(from: host)
    }

    @MainActor
    final class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate,
        NSCollectionViewDelegateFlowLayout {
        private var parent: RecyclingCardCollectionView
        private weak var host: RecyclingCardHostView?
        private var renderedSections: [RecyclingCardSection<Item>] = []
        private var lastScrollTarget: Item.ID?
        private var didApplyInitialState = false
        private var refreshGeneration = 0

        init(parent: RecyclingCardCollectionView) {
            self.parent = parent
        }

        func attach(to host: RecyclingCardHostView) {
            self.host = host
            host.collectionView.dataSource = self
            host.collectionView.delegate = self
        }

        func detach(from host: RecyclingCardHostView) {
            for item in host.collectionView.visibleItems() {
                (item as? RecyclingHostingCollectionViewItem)?.endDisplaying()
            }
            host.collectionView.dataSource = nil
            host.collectionView.delegate = nil
            self.host = nil
        }

        func apply(
            parent: RecyclingCardCollectionView,
            to host: RecyclingCardHostView,
            isInitial: Bool
        ) {
            self.parent = parent
            let dataChanged = renderedSections != parent.sections
            let appendDelta = dataChanged
                ? pureAppendDelta(from: renderedSections, to: parent.sections)
                : nil
            renderedSections = parent.sections
            host.layoutConfiguration = RecyclingCardLayoutConfiguration(
                columnCount: parent.columnCount,
                fixedItemWidth: parent.fixedItemWidth,
                itemHeight: parent.itemHeight,
                interitemSpacing: parent.interitemSpacing,
                lineSpacing: parent.lineSpacing,
                contentInsets: parent.contentInsets,
                headerHeight: parent.headerHeight,
                pinsHeaders: parent.pinsHeaders,
                scrollAxis: parent.scrollAxis
            )
            // Hosted SwiftUI views may own drag/context-menu recognizers, so click
            // handling lives on each reusable item instead of NSCollectionView's
            // selection machinery. That keeps the first click immediate.
            host.collectionView.isSelectable = false

            if isInitial {
                host.collectionView.reloadData()
                host.needsLayout = true
                host.layoutSubtreeIfNeeded()
            } else {
                // updateNSView executes while the outer SwiftUI AttributeGraph is
                // being evaluated. Replacing nested NSHostingView roots in that
                // same stack creates a parent <-> hosted-cell dependency cycle.
                // Snagit-style cells update after the page commit, once per run loop.
                if let appendDelta {
                    // 游标分页只在尾部增加条目。保留现有 cell、滚动锚点和图片解码，
                    // 只通知 NSCollectionView 新增的 index paths；避免每翻一页 reloadData。
                    host.collectionView.performBatchUpdates {
                        if !appendDelta.sections.isEmpty {
                            host.collectionView.insertSections(appendDelta.sections)
                        }
                        if !appendDelta.items.isEmpty {
                            host.collectionView.insertItems(at: Set(appendDelta.items))
                        }
                    }
                    scheduleRefresh(in: host.collectionView, reloadData: false)
                } else {
                    scheduleRefresh(in: host.collectionView, reloadData: dataChanged)
                }
                host.needsLayout = true
            }

            if !didApplyInitialState {
                lastScrollTarget = parent.scrollTarget
                didApplyInitialState = true
            } else if parent.scrollTarget != lastScrollTarget {
                lastScrollTarget = parent.scrollTarget
                scrollToTarget(in: host.collectionView)
            }
        }

        func numberOfSections(in collectionView: NSCollectionView) -> Int {
            renderedSections.count
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            numberOfItemsInSection section: Int
        ) -> Int {
            guard renderedSections.indices.contains(section) else { return 0 }
            return renderedSections[section].items.count
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            itemForRepresentedObjectAt indexPath: IndexPath
        ) -> NSCollectionViewItem {
            let item = collectionView.makeItem(
                withIdentifier: RecyclingHostingCollectionViewItem.reuseIdentifier,
                for: indexPath
            )
            guard let hosted = item as? RecyclingHostingCollectionViewItem,
                  let model = model(at: indexPath)
            else { return item }
            configure(hosted, with: model)
            return hosted
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            viewForSupplementaryElementOfKind kind: NSCollectionView.SupplementaryElementKind,
            at indexPath: IndexPath
        ) -> NSView {
            guard kind == NSCollectionView.elementKindSectionHeader else { return NSView() }
            let view = collectionView.makeSupplementaryView(
                ofKind: kind,
                withIdentifier: RecyclingHostingSectionHeader.reuseIdentifier,
                for: indexPath
            )
            guard let hosted = view as? RecyclingHostingSectionHeader,
                  renderedSections.indices.contains(indexPath.section)
            else { return view }
            hosted.configure(AnyView(parent.header(renderedSections[indexPath.section])))
            return hosted
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            willDisplay item: NSCollectionViewItem,
            forRepresentedObjectAt indexPath: IndexPath
        ) {
            (item as? RecyclingHostingCollectionViewItem)?.beginDisplaying()
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            didEndDisplaying item: NSCollectionViewItem,
            forRepresentedObjectAt indexPath: IndexPath
        ) {
            (item as? RecyclingHostingCollectionViewItem)?.endDisplaying()
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            layout collectionViewLayout: NSCollectionViewLayout,
            insetForSectionAt section: Int
        ) -> NSEdgeInsets {
            guard var insets = host?.resolvedSectionInsets else {
                return parent.contentInsets
            }
            guard parent.scrollAxis == .vertical else { return insets }
            // The outer bottom safe area belongs only after the final section.
            // Earlier sections need one ordinary row gap, not a toolbar-sized hole.
            insets.bottom = section == renderedSections.count - 1
                ? parent.contentInsets.bottom
                : parent.lineSpacing
            return insets
        }

        private func configure(_ item: RecyclingHostingCollectionViewItem, with model: Item) {
            item.configure(
                rootView: AnyView(parent.card(model)),
                onDisplay: { [weak self] in self?.parent.onDisplay(model) },
                onEndDisplay: { [weak self] in self?.parent.onEndDisplay(model) },
                onSelect: parent.handlesSelection ? { [weak self] modifiers in
                    self?.parent.onSelect(model, modifiers)
                } : nil,
                onDoubleClick: parent.handlesSelection ? { [weak self] in
                    self?.parent.onDoubleClick(model)
                } : nil,
                selectionHitTest: parent.handlesSelection ? { [weak self] point, size in
                    self?.parent.selectionHitTest(model, point, size) ?? true
                } : nil
            )
        }

        private func scheduleRefresh(
            in collectionView: NSCollectionView,
            reloadData: Bool
        ) {
            refreshGeneration &+= 1
            let generation = refreshGeneration
            DispatchQueue.main.async { [weak self, weak collectionView] in
                guard let self,
                      let collectionView,
                      generation == self.refreshGeneration
                else { return }
                if reloadData {
                    collectionView.reloadData()
                } else {
                    self.refreshVisibleItems(in: collectionView)
                    self.refreshVisibleHeaders(in: collectionView)
                }
            }
        }

        private struct AppendDelta {
            let sections: IndexSet
            let items: [IndexPath]
        }

        /// 返回 nil 表示排序/删除/分组发生变化，必须完整 reload；非 nil 表示所有旧 ID
        /// 都是新快照的稳定前缀，可安全做增量插入。元素内容变化仍由 visible refresh 更新。
        private func pureAppendDelta(
            from old: [RecyclingCardSection<Item>],
            to new: [RecyclingCardSection<Item>]
        ) -> AppendDelta? {
            guard new.count >= old.count else { return nil }
            var insertedItems: [IndexPath] = []
            for sectionIndex in old.indices {
                let previous = old[sectionIndex]
                let current = new[sectionIndex]
                guard previous.id == current.id,
                      current.items.count >= previous.items.count,
                      Array(current.items.prefix(previous.items.count)).map(\.id)
                        == previous.items.map(\.id)
                else { return nil }
                if current.items.count > previous.items.count {
                    insertedItems.append(contentsOf: (previous.items.count..<current.items.count).map {
                        IndexPath(item: $0, section: sectionIndex)
                    })
                }
            }
            let insertedSections = old.count < new.count
                ? IndexSet(integersIn: old.count..<new.count)
                : IndexSet()
            return AppendDelta(sections: insertedSections, items: insertedItems)
        }

        private func refreshVisibleItems(in collectionView: NSCollectionView) {
            for item in collectionView.visibleItems() {
                guard let hosted = item as? RecyclingHostingCollectionViewItem,
                      let indexPath = collectionView.indexPath(for: item),
                      let model = model(at: indexPath)
                else { continue }
                configure(hosted, with: model)
            }
        }

        private func refreshVisibleHeaders(in collectionView: NSCollectionView) {
            guard parent.headerHeight > 0 else { return }
            for sectionIndex in renderedSections.indices {
                let indexPath = IndexPath(item: 0, section: sectionIndex)
                guard let view = collectionView.supplementaryView(
                    forElementKind: NSCollectionView.elementKindSectionHeader,
                    at: indexPath
                ) as? RecyclingHostingSectionHeader
                else { continue }
                view.configure(AnyView(parent.header(renderedSections[sectionIndex])))
            }
        }

        private func model(at indexPath: IndexPath) -> Item? {
            guard renderedSections.indices.contains(indexPath.section),
                  renderedSections[indexPath.section].items.indices.contains(indexPath.item)
            else { return nil }
            return renderedSections[indexPath.section].items[indexPath.item]
        }

        private func scrollToTarget(in collectionView: NSCollectionView) {
            guard let indexPath = targetIndexPath() else { return }
            collectionView.scrollToItems(
                at: [indexPath],
                scrollPosition: parent.scrollAxis == .horizontal
                    ? .nearestHorizontalEdge
                    : .nearestVerticalEdge
            )
        }

        private func targetIndexPath() -> IndexPath? {
            guard let target = parent.scrollTarget else { return nil }
            for (sectionIndex, section) in renderedSections.enumerated() {
                guard let itemIndex = section.items.firstIndex(where: { $0.id == target }) else {
                    continue
                }
                return IndexPath(item: itemIndex, section: sectionIndex)
            }
            return nil
        }

    }
}

fileprivate struct RecyclingCardLayoutConfiguration {
    let columnCount: Int
    let fixedItemWidth: CGFloat?
    let itemHeight: CGFloat
    let interitemSpacing: CGFloat
    let lineSpacing: CGFloat
    let contentInsets: NSEdgeInsets
    let headerHeight: CGFloat
    let pinsHeaders: Bool
    let scrollAxis: RecyclingCardScrollAxis
}

@MainActor
final class RecyclingCardHostView: NSView {
    let scrollView = NSScrollView()
    let collectionView = NSCollectionView()
    private let flowLayout = NSCollectionViewFlowLayout()
    private var viewportObserver: NSObjectProtocol?
    private var hoverResyncWorkItem: DispatchWorkItem?
    fileprivate var layoutConfiguration: RecyclingCardLayoutConfiguration?
    fileprivate var resolvedSectionInsets: NSEdgeInsets?
    private var appliedItemSize = NSSize.zero
    private var appliedSectionInsets = NSEdgeInsets()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        collectionView.collectionViewLayout = flowLayout
        collectionView.isSelectable = false
        collectionView.backgroundColors = [.clear]
        collectionView.register(
            RecyclingHostingCollectionViewItem.self,
            forItemWithIdentifier: RecyclingHostingCollectionViewItem.reuseIdentifier
        )
        collectionView.register(
            RecyclingHostingSectionHeader.self,
            forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader,
            withIdentifier: RecyclingHostingSectionHeader.reuseIdentifier
        )

        scrollView.documentView = collectionView
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.contentView.drawsBackground = false
        scrollView.contentView.postsBoundsChangedNotifications = true
        viewportObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.viewportDidMove() }
        }
        addSubview(scrollView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    deinit {
        hoverResyncWorkItem?.cancel()
        if let viewportObserver {
            NotificationCenter.default.removeObserver(viewportObserver)
        }
    }

    /// Scrolling moves cells underneath a stationary pointer. AppKit may suppress
    /// tracking-area enter/exit events during momentum, so clear any stale hover
    /// immediately and perform one coordinate-based hit test after the viewport
    /// settles. Bounds notifications also cover scrollbar and programmatic scrolls.
    private func viewportDidMove() {
        hoverResyncWorkItem?.cancel()
        for item in collectionView.visibleItems() {
            (item as? RecyclingHostingCollectionViewItem)?.suspendHoverForViewportMovement()
        }

        let workItem = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                for item in self.collectionView.visibleItems() {
                    (item as? RecyclingHostingCollectionViewItem)?
                        .resumeHoverAfterViewportMovement()
                }
                self.hoverResyncWorkItem = nil
            }
        }
        hoverResyncWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: workItem)
    }

    override func layout() {
        super.layout()
        scrollView.frame = bounds
        applyLayoutConfiguration()
    }

    private func applyLayoutConfiguration() {
        guard let configuration = layoutConfiguration else { return }
        // 实时拉伸期间只改变 viewport，不按每一个鼠标像素重算卡片和使整套
        // collection layout 失效。窗口结束 live resize 后 AppKit 会再次 layout，
        // 届时一次性应用最终列宽/边距。
        guard window?.inLiveResize != true || appliedItemSize == .zero else { return }
        let isHorizontal = configuration.scrollAxis == .horizontal
        flowLayout.scrollDirection = isHorizontal ? .horizontal : .vertical
        scrollView.hasVerticalScroller = !isHorizontal
        scrollView.hasHorizontalScroller = isHorizontal
        let columns = max(1, configuration.columnCount)
        let contentWidth = max(1, scrollView.contentSize.width)
        let naturalWidth = CGFloat(columns) * (configuration.fixedItemWidth ?? 0)
            + CGFloat(max(0, columns - 1)) * configuration.interitemSpacing

        let leftInset: CGFloat
        let rightInset: CGFloat
        let itemWidth: CGFloat
        if isHorizontal {
            leftInset = configuration.contentInsets.left
            rightInset = configuration.contentInsets.right
            itemWidth = configuration.fixedItemWidth ?? max(
                1,
                contentWidth - leftInset - rightInset
            )
        } else if let fixedWidth = configuration.fixedItemWidth {
            leftInset = max(configuration.contentInsets.left, (contentWidth - naturalWidth) / 2)
            rightInset = configuration.contentInsets.right
            itemWidth = fixedWidth
        } else {
            leftInset = configuration.contentInsets.left
            rightInset = configuration.contentInsets.right
            let availableWidth = contentWidth
                - leftInset
                - rightInset
                - CGFloat(max(0, columns - 1)) * configuration.interitemSpacing
            itemWidth = max(1, floor(availableWidth / CGFloat(columns)))
        }

        let itemSize = NSSize(width: itemWidth, height: configuration.itemHeight)
        let sectionInsets = NSEdgeInsets(
            top: configuration.contentInsets.top,
            left: leftInset,
            bottom: configuration.contentInsets.bottom,
            right: rightInset
        )
        guard itemSize != appliedItemSize || !sameInsets(sectionInsets, appliedSectionInsets) else {
            return
        }
        appliedItemSize = itemSize
        appliedSectionInsets = sectionInsets
        resolvedSectionInsets = sectionInsets
        flowLayout.itemSize = itemSize
        flowLayout.minimumInteritemSpacing = configuration.interitemSpacing
        flowLayout.minimumLineSpacing = configuration.lineSpacing
        flowLayout.sectionInset = sectionInsets
        flowLayout.headerReferenceSize = NSSize(width: 1, height: configuration.headerHeight)
        flowLayout.sectionHeadersPinToVisibleBounds = configuration.pinsHeaders
        flowLayout.invalidateLayout()
    }

    private func sameInsets(_ lhs: NSEdgeInsets, _ rhs: NSEdgeInsets) -> Bool {
        lhs.top == rhs.top
            && lhs.left == rhs.left
            && lhs.bottom == rhs.bottom
            && lhs.right == rhs.right
    }
}

@MainActor
private final class RecyclingHostingCollectionViewItem: NSCollectionViewItem,
    NSGestureRecognizerDelegate {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("RecyclingHostingCollectionViewItem")

    private var hostingView: NSHostingView<AnyView>?
    private var onDisplay: (() -> Void)?
    private var onEndDisplay: (() -> Void)?
    private var onSelect: ((NSEvent.ModifierFlags) -> Void)?
    private var onDoubleClick: (() -> Void)?
    private var selectionHitTest: ((NSPoint, NSSize) -> Bool)?
    private var isDisplaying = false
    private var singleClick: NSClickGestureRecognizer!
    private var doubleClick: NSClickGestureRecognizer!
    private let hoverState = RecyclingCardHoverState()

    override func loadView() {
        view = NSView(frame: .zero)
        singleClick = NSClickGestureRecognizer(target: self, action: #selector(handleSingleClick))
        singleClick.numberOfClicksRequired = 1
        singleClick.delaysPrimaryMouseButtonEvents = false
        singleClick.delegate = self
        view.addGestureRecognizer(singleClick)

        doubleClick = NSClickGestureRecognizer(target: self, action: #selector(handleDoubleClick))
        doubleClick.numberOfClicksRequired = 2
        doubleClick.delaysPrimaryMouseButtonEvents = false
        doubleClick.delegate = self
        view.addGestureRecognizer(doubleClick)

        // 跟踪区属于稳定的 AppKit cell，而不是会反复替换 rootView 的
        // NSHostingView。`.inVisibleRect` 会在复用和尺寸变化时自动跟随可见区域。
        view.addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    func configure(
        rootView: AnyView,
        onDisplay: @escaping () -> Void,
        onEndDisplay: @escaping () -> Void,
        onSelect: ((NSEvent.ModifierFlags) -> Void)?,
        onDoubleClick: (() -> Void)?,
        selectionHitTest: ((NSPoint, NSSize) -> Bool)?
    ) {
        self.onDisplay = onDisplay
        self.onEndDisplay = onEndDisplay
        self.onSelect = onSelect
        self.onDoubleClick = onDoubleClick
        self.selectionHitTest = selectionHitTest
        singleClick.isEnabled = onSelect != nil
        doubleClick.isEnabled = onDoubleClick != nil
        let hostedRoot = AnyView(RecyclingCardHoverHost(
            state: hoverState,
            content: rootView
        ))
        if let hostingView {
            hostingView.rootView = hostedRoot
        } else {
            let hostingView = NSHostingView(rootView: hostedRoot)
            hostingView.frame = view.bounds
            hostingView.autoresizingMask = [.width, .height]
            view.addSubview(hostingView)
            self.hostingView = hostingView
        }
        if isDisplaying { synchronizeHoverWithPointer() }
    }

    override func mouseEntered(with event: NSEvent) {
        hoverState.setHovered(isDisplaying)
    }

    override func mouseExited(with event: NSEvent) {
        hoverState.setHovered(false)
    }

    @objc private func handleSingleClick() {
        let modifiers = NSApp.currentEvent?.modifierFlags
            .intersection(.deviceIndependentFlagsMask) ?? []
        onSelect?(modifiers)
    }

    @objc private func handleDoubleClick() {
        onDoubleClick?()
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: NSGestureRecognizer) -> Bool {
        guard gestureRecognizer === singleClick || gestureRecognizer === doubleClick,
              let event = NSApp.currentEvent
        else { return true }

        let point = view.convert(event.locationInWindow, from: nil)
        guard RecyclingCardClickRouting.shouldHandleCardClick(
            hitView: view.hitTest(point),
            cellView: view
        ) else { return false }
        return selectionHitTest?(point, view.bounds.size) ?? true
    }

    func gestureRecognizer(
        _ gestureRecognizer: NSGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: NSGestureRecognizer
    ) -> Bool {
        // First click selects immediately; a second click may also complete the
        // double-click recognizer. No failure dependency means no 300ms wait.
        true
    }

    func beginDisplaying() {
        guard !isDisplaying else { return }
        isDisplaying = true
        synchronizeHoverWithPointer()
        onDisplay?()
    }

    func endDisplaying() {
        guard isDisplaying else { return }
        isDisplaying = false
        hoverState.setHovered(false)
        onEndDisplay?()
    }

    /// 新 cell 可能刚好在静止指针下出现（翻页、复用、窗口缩放），
    /// 此时系统不一定再发 mouseEntered。用窗口当前鼠标位置对齐一次。
    private func synchronizeHoverWithPointer() {
        guard isDisplaying, let window = view.window else {
            hoverState.setHovered(false)
            return
        }
        let localPoint = view.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        hoverState.setHovered(view.bounds.contains(localPoint))
    }

    func suspendHoverForViewportMovement() {
        hoverState.setHovered(false)
    }

    func resumeHoverAfterViewportMovement() {
        synchronizeHoverWithPointer()
    }

    override func prepareForReuse() {
        endDisplaying()
        hoverState.setHovered(false)
        hostingView?.rootView = AnyView(EmptyView())
        onDisplay = nil
        onEndDisplay = nil
        onSelect = nil
        onDoubleClick = nil
        selectionHitTest = nil
        super.prepareForReuse()
    }
}

/// 卡片级手势只处理内容表面；按钮、输入框和文本编辑器保留自己的事件。
/// 独立成纯视图树判断，便于覆盖复用 cell 的事件路由契约。
enum RecyclingCardClickRouting {
    static func shouldHandleCardClick(hitView: NSView?, cellView: NSView) -> Bool {
        var candidate = hitView
        while let view = candidate, view !== cellView {
            if view is NSControl || view is NSTextView {
                return false
            }
            candidate = view.superview
        }
        return true
    }
}

@MainActor
private final class RecyclingCardHoverState: ObservableObject {
    @Published private(set) var isHovered = false

    func setHovered(_ hovered: Bool) {
        guard hovered != isHovered else { return }
        isHovered = hovered
    }
}

private struct RecyclingCardHoverHost: View {
    @ObservedObject var state: RecyclingCardHoverState
    let content: AnyView

    var body: some View {
        content.environment(\.recyclingCardIsHovered, state.isHovered)
    }
}

@MainActor
private final class RecyclingHostingSectionHeader: NSView, NSCollectionViewElement {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("RecyclingHostingSectionHeader")
    private var hostingView: NSHostingView<AnyView>?

    func configure(_ rootView: AnyView) {
        if let hostingView {
            hostingView.rootView = rootView
        } else {
            let hostingView = NSHostingView(rootView: rootView)
            hostingView.frame = bounds
            hostingView.autoresizingMask = [.width, .height]
            addSubview(hostingView)
            self.hostingView = hostingView
        }
    }

    override func prepareForReuse() {
        hostingView?.rootView = AnyView(EmptyView())
        super.prepareForReuse()
    }
}
