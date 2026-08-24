import AppKit
import SwiftUI

/// Bridges AppKit's actual scroll/live-resize lifecycle into two coarse SwiftUI
/// booleans. It never publishes offsets, so continuous wheel and resize events
/// do not invalidate the gallery tree every frame.
struct GalleryInteractionTracker: ViewModifier {
    @Binding var isScrolling: Bool
    @Binding var isLiveResizing: Bool

    func body(content: Content) -> some View {
        content.background {
            GalleryInteractionProbe(
                isScrolling: $isScrolling,
                isLiveResizing: $isLiveResizing
            )
            .allowsHitTesting(false)
        }
    }
}

private struct GalleryInteractionProbe: NSViewRepresentable {
    @Binding var isScrolling: Bool
    @Binding var isLiveResizing: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView(frame: .zero)
        view.coordinator = context.coordinator
        context.coordinator.updateBindings(
            isScrolling: $isScrolling,
            isLiveResizing: $isLiveResizing
        )
        DispatchQueue.main.async { [weak view, weak coordinator = context.coordinator] in
            guard let view, let coordinator else { return }
            coordinator.attach(from: view)
        }
        return view
    }

    func updateNSView(_ nsView: ProbeView, context: Context) {
        context.coordinator.updateBindings(
            isScrolling: $isScrolling,
            isLiveResizing: $isLiveResizing
        )
        context.coordinator.attach(from: nsView)
    }

    static func dismantleNSView(_ nsView: ProbeView, coordinator: Coordinator) {
        coordinator.detach()
        nsView.coordinator = nil
    }

    @MainActor
    final class Coordinator {
        private var scrollingBinding: Binding<Bool>?
        private var liveResizeBinding: Binding<Bool>?
        private weak var scrollView: NSScrollView?
        private weak var window: NSWindow?
        private var scrollObservers: [NSObjectProtocol] = []
        private var windowObservers: [NSObjectProtocol] = []

        func updateBindings(
            isScrolling: Binding<Bool>,
            isLiveResizing: Binding<Bool>
        ) {
            scrollingBinding = isScrolling
            liveResizeBinding = isLiveResizing
        }

        func attach(from view: NSView) {
            if window !== view.window {
                detachWindowObservers()
                window = view.window
                attachWindowObservers()
            }

            guard let candidate = findVerticalScrollView(from: view),
                  candidate !== scrollView
            else { return }
            detachScrollObservers()
            scrollView = candidate
            attachScrollObservers(to: candidate)
        }

        func detach() {
            detachScrollObservers()
            detachWindowObservers()
            scrollView = nil
            window = nil
        }

        private func attachScrollObservers(to scrollView: NSScrollView) {
            let center = NotificationCenter.default
            scrollObservers = [
                center.addObserver(
                    forName: NSScrollView.willStartLiveScrollNotification,
                    object: scrollView,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.scrollingBinding?.wrappedValue = true }
                },
                center.addObserver(
                    forName: NSScrollView.didLiveScrollNotification,
                    object: scrollView,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.scrollingBinding?.wrappedValue = true }
                },
                center.addObserver(
                    forName: NSScrollView.didEndLiveScrollNotification,
                    object: scrollView,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.scrollingBinding?.wrappedValue = false }
                },
            ]
        }

        private func attachWindowObservers() {
            guard let window else { return }
            let center = NotificationCenter.default
            windowObservers = [
                center.addObserver(
                    forName: NSWindow.willStartLiveResizeNotification,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.liveResizeBinding?.wrappedValue = true }
                },
                center.addObserver(
                    forName: NSWindow.didEndLiveResizeNotification,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.liveResizeBinding?.wrappedValue = false }
                },
            ]
            liveResizeBinding?.wrappedValue = window.inLiveResize
        }

        private func detachScrollObservers() {
            let center = NotificationCenter.default
            scrollObservers.forEach(center.removeObserver)
            scrollObservers.removeAll(keepingCapacity: true)
            scrollingBinding?.wrappedValue = false
        }

        private func detachWindowObservers() {
            let center = NotificationCenter.default
            windowObservers.forEach(center.removeObserver)
            windowObservers.removeAll(keepingCapacity: true)
            liveResizeBinding?.wrappedValue = false
        }

        /// A SwiftUI background can be placed inside the document view or as a
        /// sibling of NSScrollView. Search the nearest ancestor subtree before
        /// widening the search, and only accept vertically configured scrollers.
        private func findVerticalScrollView(from view: NSView) -> NSScrollView? {
            if let enclosing = view.enclosingScrollView,
               enclosing.hasVerticalScroller {
                return enclosing
            }

            var ancestor = view.superview
            while let candidate = ancestor {
                if let found = firstVerticalScrollView(in: candidate) { return found }
                ancestor = candidate.superview
            }
            return nil
        }

        private func firstVerticalScrollView(in root: NSView) -> NSScrollView? {
            for child in root.subviews {
                if let scrollView = child as? NSScrollView,
                   scrollView.hasVerticalScroller {
                    return scrollView
                }
                if let nested = firstVerticalScrollView(in: child) { return nested }
            }
            return nil
        }

        deinit {
            let center = NotificationCenter.default
            scrollObservers.forEach(center.removeObserver)
            windowObservers.forEach(center.removeObserver)
        }
    }

    final class ProbeView: NSView {
        weak var coordinator: Coordinator?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            coordinator?.attach(from: self)
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            coordinator?.attach(from: self)
        }
    }
}
