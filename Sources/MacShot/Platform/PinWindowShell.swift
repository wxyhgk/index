import AppKit

/// 图片钉图与分子钉图共用的窗口外壳。具体内容仍由各自宿主管理。
class PinnedContentPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class PinPassthroughRegistry {
    static let shared = PinPassthroughRegistry()

    private final class WeakEntry {
        weak var value: AnyObject?
        init(_ value: AnyObject) { self.value = value }
    }

    private var entries: [ObjectIdentifier: WeakEntry] = [:]

    var hasPassthroughPins: Bool {
        removeDeadEntries()
        return !entries.isEmpty
    }

    func register(_ pin: any PinPassthroughControlling) {
        entries[ObjectIdentifier(pin)] = WeakEntry(pin)
    }

    func unregister(_ pin: any PinPassthroughControlling) {
        entries.removeValue(forKey: ObjectIdentifier(pin))
    }

    func liftAll() {
        let pins = entries.values.compactMap {
            $0.value as? any PinPassthroughControlling
        }
        entries.removeAll()
        pins.forEach { $0.setPinPassthrough(false) }
    }

    private func removeDeadEntries() {
        entries = entries.filter { $0.value.value != nil }
    }
}
