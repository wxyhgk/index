import AppKit

/// 跟踪所有活跃的 Pin 窗口。弱引用，窗口关闭后自动清除。
@MainActor
final class PinWindowRegistry {
    static let shared = PinWindowRegistry()

    private final class WeakEntry {
        weak var value: NSWindowController?
        init(_ value: NSWindowController) { self.value = value }
    }

    private var entries: [ObjectIdentifier: WeakEntry] = [:]
    private var order: [ObjectIdentifier] = []

    func register(_ controller: NSWindowController) {
        guard let window = controller.window else { return }
        let key = ObjectIdentifier(window)
        guard entries[key] == nil else { return }
        entries[key] = WeakEntry(controller)
        order.append(key)
    }

    func unregister(_ controller: NSWindowController) {
        guard let window = controller.window else { return }
        let key = ObjectIdentifier(window)
        entries.removeValue(forKey: key)
        order.removeAll { $0 == key }
    }

    /// 按注册顺序返回当前活跃的 Pin 窗口控制器。
    var activeControllers: [NSWindowController] {
        removeDeadEntries()
        return order.compactMap { entries[$0]?.value }
    }

    var activeWindows: [NSWindow] {
        activeControllers.compactMap { $0.window }
    }

    var count: Int {
        removeDeadEntries()
        return entries.count
    }

    private func removeDeadEntries() {
        let dead = entries.filter { $0.value.value == nil }
        for (key, _) in dead {
            entries.removeValue(forKey: key)
            order.removeAll { $0 == key }
        }
    }
}
