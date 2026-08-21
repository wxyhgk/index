import AppKit

/// 窗口生命周期与激活策略的统一管理。
///
/// 此前并存四套机制：两个单例、一份 `static var living` 集合、一个实例数组；
/// 激活策略则在三个窗口控制器里各写了一遍「遍历 NSApp.windows 猜还有没有别的窗口」。
/// 那个启发式有两个真 bug：图库那份没有守卫（关图库会让设置窗口的菜单栏消失），
/// 而选区覆盖层是 NSWindow 不是 NSPanel，截图时会被算成「正经窗口」，让 App 卡在 .regular。
///
/// 现在改成**显式引用计数**：谁需要 Dock 图标，谁在注册时说明。不再有猜测。
@MainActor
final class WindowRegistry {

    static let shared = WindowRegistry()

    /// 需要 Dock 图标的窗口。
    private var dockWindows: Set<ObjectIdentifier> = []
    /// 由注册表持有生命周期的控制器，取代各处自己写的 `static var living`。
    private var retained: [ObjectIdentifier: NSWindowController] = [:]
    private var observers: [ObjectIdentifier: NSObjectProtocol] = [:]

    private init() {}

    /// 展示一个窗口。
    /// - Parameters:
    ///   - dockIcon: 这是不是一个「正经窗口」。图库、设置是；钉图这类浮动面板不是。
    ///   - retain: 由注册表持有控制器直到窗口关闭。单例窗口不需要。
    func present(_ controller: NSWindowController, dockIcon: Bool, retain: Bool = false) {
        guard let window = controller.window else { return }
        let key = ObjectIdentifier(window)

        if retain { retained[key] = controller }
        observe(window, key: key)

        if dockIcon {
            dockWindows.insert(key)
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            controller.showWindow(nil)
            window.makeKeyAndOrderFront(nil)
        } else {
            controller.showWindow(nil)
            window.orderFrontRegardless()
        }
    }

    private func observe(_ window: NSWindow, key: ObjectIdentifier) {
        if let existing = observers[key] {
            NotificationCenter.default.removeObserver(existing)
        }
        observers[key] = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                WindowRegistry.shared.handleClose(key)
            }
        }
    }

    private func handleClose(_ key: ObjectIdentifier) {
        dockWindows.remove(key)

        if let observer = observers.removeValue(forKey: key) {
            NotificationCenter.default.removeObserver(observer)
        }

        // 通知是在窗口自己的 close() 调用栈里发出的，此刻放掉最后一个引用会在
        // 控制器执行中途把它析构掉。延到下一轮 runloop 再撒手。
        if let controller = retained.removeValue(forKey: key) {
            DispatchQueue.main.async { _ = controller }
        }

        if dockWindows.isEmpty {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
