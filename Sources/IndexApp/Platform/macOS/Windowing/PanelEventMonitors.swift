import AppKit

/// 面板的全局/本地事件监听持有者。
///
/// 四个面板此前各写一份 `NSEvent.addLocalMonitorForEvents` + 手动 remove，
/// 漏 remove 就是监听泄漏。这里把生命周期收在一处，并保证重复安装先清理。
@MainActor
final class PanelEventMonitors {

    private var localKey: Any?
    private var globalClick: Any?

    /// 本地键盘监听。`handler` 返回 nil 表示消费掉事件。
    func installLocalKey(
        matching mask: NSEvent.EventTypeMask = [.keyDown],
        _ handler: @escaping (NSEvent) -> NSEvent?
    ) {
        removeLocalKey()
        localKey = NSEvent.addLocalMonitorForEvents(matching: mask) { event in
            MainActor.assumeIsolated { handler(event) }
        }
    }

    func removeLocalKey() {
        if let localKey {
            NSEvent.removeMonitor(localKey)
            self.localKey = nil
        }
    }

    /// 全局鼠标按下监听（点面板外关闭）。回调在线程主线程执行。
    func installGlobalClick(_ handler: @escaping () -> Void) {
        removeGlobalClick()
        globalClick = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { _ in
            MainActor.assumeIsolated { handler() }
        }
    }

    func removeGlobalClick() {
        if let globalClick {
            NSEvent.removeMonitor(globalClick)
            self.globalClick = nil
        }
    }

    func removeAll() {
        removeLocalKey()
        removeGlobalClick()
    }
}
