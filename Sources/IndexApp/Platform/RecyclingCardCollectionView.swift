import AppKit
import SwiftUI

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
                scheduleRefresh(in: host.collectionView, reloadData: dataChanged)
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
        addSubview(scrollView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        scrollView.frame = bounds
        applyLayoutConfiguration()
    }

    private func applyLayoutConfiguration() {
        guard let configuration = layoutConfiguration else { return }
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
    private var isDisplaying = false
    private var singleClick: NSClickGestureRecognizer!
    private var doubleClick: NSClickGestureRecognizer!

    override func loadView() {
        view = NSView(frame: .zero)
        singleClick = NSClickGestureRecognizer(target: self, action: #selector(handleSingleClick))
        singleClick.numberOfClicksRequired = 1
        singleClick.delegate = self
        view.addGestureRecognizer(singleClick)

        doubleClick = NSClickGestureRecognizer(target: self, action: #selector(handleDoubleClick))
        doubleClick.numberOfClicksRequired = 2
        doubleClick.delegate = self
        view.addGestureRecognizer(doubleClick)
    }

    func configure(
        rootView: AnyView,
        onDisplay: @escaping () -> Void,
        onEndDisplay: @escaping () -> Void,
        onSelect: ((NSEvent.ModifierFlags) -> Void)?,
        onDoubleClick: (() -> Void)?
    ) {
        self.onDisplay = onDisplay
        self.onEndDisplay = onEndDisplay
        self.onSelect = onSelect
        self.onDoubleClick = onDoubleClick
        singleClick.isEnabled = onSelect != nil
        doubleClick.isEnabled = onDoubleClick != nil
        if let hostingView {
            hostingView.rootView = rootView
        } else {
            let hostingView = NSHostingView(rootView: rootView)
            hostingView.frame = view.bounds
            hostingView.autoresizingMask = [.width, .height]
            view.addSubview(hostingView)
            self.hostingView = hostingView
        }
    }

    @objc private func handleSingleClick() {
        let modifiers = NSApp.currentEvent?.modifierFlags
            .intersection(.deviceIndependentFlagsMask) ?? []
        onSelect?(modifiers)
    }

    @objc private func handleDoubleClick() {
        onDoubleClick?()
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
        onDisplay?()
    }

    func endDisplaying() {
        guard isDisplaying else { return }
        isDisplaying = false
        onEndDisplay?()
    }

    override func prepareForReuse() {
        endDisplaying()
        hostingView?.rootView = AnyView(EmptyView())
        onDisplay = nil
        onEndDisplay = nil
        onSelect = nil
        onDoubleClick = nil
        super.prepareForReuse()
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
