import Foundation
import SwiftUI

/// A lightweight description of one thumbnail request. The gallery owns the
/// ordering; the loader owns decoding, request coalescing, and the memory cache.
struct ViewportThumbnailEntry: Equatable, Sendable {
    /// Grid identity and cache identity are deliberately different: imported or
    /// duplicated records may point at the same content-addressed thumbnail.
    let identity: String
    let key: String
    let url: URL
}

/// Pure range math for the rolling preheat window.
///
/// `LazyVGrid` already mounts a small overscan area. We treat that mounted span
/// as the visible rectangle, then extend it in the current travel direction.
/// A large midpoint jump gets a deeper leading window so a fast fling does not
/// immediately outrun the cache.
enum ViewportPreheatWindow {
    static func desiredRange(
        mountedIndices: [Int],
        itemCount: Int,
        columnCount: Int,
        midpointDelta: Int
    ) -> Range<Int> {
        guard itemCount > 0,
              let first = mountedIndices.min(),
              let last = mountedIndices.max()
        else { return 0..<0 }

        let columns = max(1, columnCount)
        let isFast = abs(midpointDelta) >= columns * 2
        let leadingRows = isFast ? 8 : 4
        let trailingRows = isFast ? 1 : 2
        let movingBackward = midpointDelta < 0
        let lowerRows = movingBackward ? leadingRows : trailingRows
        let upperRows = movingBackward ? trailingRows : leadingRows

        let lower = max(0, first - lowerRows * columns)
        let upper = min(itemCount, last + 1 + upperRows * columns)
        return lower..<max(lower, upper)
    }
}

/// Gallery-level differential preheater.
///
/// Cards only report mount/unmount. This object coalesces those reports to one
/// reconciliation per run-loop slice, computes the new rolling window, starts
/// work for added entries, and cancels work for entries that left the window.
/// ThumbnailLoadPipeline supplies the bounded four-wide decoder underneath.
@MainActor
final class ViewportThumbnailPreheater: ObservableObject {
    private let loader: any ThumbnailLoading
    private var entries: [ViewportThumbnailEntry] = []
    private var indexByIdentity: [String: Int] = [:]
    private var mountedIdentities: Set<String> = []
    private var columnCount = 1
    private var previousMidpoint: Int?
    private var isSuspended = false

    private var reconcileTask: Task<Void, Never>?
    private var loadTasks: [String: Task<Void, Never>] = [:]
    private var requestIDs: [String: UUID] = [:]

    convenience init() {
        self.init(loader: ThumbnailLoader.shared)
    }

    init(loader: any ThumbnailLoading) {
        self.loader = loader
    }

    deinit {
        reconcileTask?.cancel()
        loadTasks.values.forEach { $0.cancel() }
    }

    func configure(entries: [ViewportThumbnailEntry], columnCount: Int) {
        self.entries = entries
        self.columnCount = max(1, columnCount)
        indexByIdentity = Dictionary(
            entries.enumerated().map { ($0.element.identity, $0.offset) },
            uniquingKeysWith: { _, latest in latest }
        )
        mountedIdentities.formIntersection(indexByIdentity.keys)
        cancelLoadsOutside(Set(entries.map(\.key)))
        scheduleReconcile()
    }

    func mounted(_ identity: String) {
        guard mountedIdentities.insert(identity).inserted else { return }
        scheduleReconcile()
    }

    func unmounted(_ identity: String) {
        guard mountedIdentities.remove(identity) != nil else { return }
        scheduleReconcile()
    }

    func setSuspended(_ suspended: Bool) {
        guard isSuspended != suspended else { return }
        isSuspended = suspended
        if suspended {
            reconcileTask?.cancel()
            reconcileTask = nil
            cancelAllLoads()
        } else {
            scheduleReconcile()
        }
    }

    func reset() {
        entries = []
        indexByIdentity = [:]
        mountedIdentities = []
        previousMidpoint = nil
        reconcileTask?.cancel()
        reconcileTask = nil
        cancelAllLoads()
    }

    private func scheduleReconcile() {
        guard !isSuspended, reconcileTask == nil else { return }
        reconcileTask = Task { [weak self] in
            // A short coalescing window turns a row of onAppear callbacks into
            // one range diff without delaying work by a perceptible frame.
            try? await Task.sleep(for: .milliseconds(8))
            guard !Task.isCancelled, let self else { return }
            reconcileTask = nil
            reconcile()
        }
    }

    private func reconcile() {
        guard !isSuspended else { return }
        let mountedIndices = mountedIdentities.compactMap { indexByIdentity[$0] }
        guard let first = mountedIndices.min(), let last = mountedIndices.max() else {
            previousMidpoint = nil
            cancelAllLoads()
            return
        }

        let midpoint = first + (last - first) / 2
        let delta = previousMidpoint.map { midpoint - $0 } ?? 0
        previousMidpoint = midpoint
        let range = ViewportPreheatWindow.desiredRange(
            mountedIndices: mountedIndices,
            itemCount: entries.count,
            columnCount: columnCount,
            midpointDelta: delta
        )
        let desiredEntries = entries[range]
        let desiredKeys = Set(desiredEntries.map(\.key))

        // This is the crucial differential step: old queued requests disappear
        // immediately instead of remaining behind the user's current viewport.
        cancelLoadsOutside(desiredKeys)

        for entry in desiredEntries {
            guard loadTasks[entry.key] == nil,
                  loader.cachedImage(forKey: entry.key) == nil
            else { continue }

            let requestID = UUID()
            requestIDs[entry.key] = requestID
            loadTasks[entry.key] = Task(priority: .utility) { [weak self, loader] in
                _ = await loader.load(url: entry.url, key: entry.key)
                guard !Task.isCancelled else { return }
                self?.finishLoad(forKey: entry.key, requestID: requestID)
            }
        }
    }

    private func finishLoad(forKey key: String, requestID: UUID) {
        guard requestIDs[key] == requestID else { return }
        requestIDs.removeValue(forKey: key)
        loadTasks.removeValue(forKey: key)
    }

    private func cancelLoadsOutside(_ desiredKeys: Set<String>) {
        for key in loadTasks.keys where !desiredKeys.contains(key) {
            loadTasks.removeValue(forKey: key)?.cancel()
            requestIDs.removeValue(forKey: key)
        }
    }

    private func cancelAllLoads() {
        loadTasks.values.forEach { $0.cancel() }
        loadTasks.removeAll(keepingCapacity: true)
        requestIDs.removeAll(keepingCapacity: true)
    }
}
