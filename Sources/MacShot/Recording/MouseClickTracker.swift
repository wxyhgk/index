import AppKit

/// 录制期间的鼠标点击记录器：把每次点击映射到**净录制时间**（= 成品视频时间轴）。
///
/// 用全局鼠标事件监视器：
///   · 只收到发给**其他 App** 的点击 —— 点自己的控制条不算（那不是被录的操作）
///   · 鼠标全局监听不需要辅助功能权限（只有键盘全局监听才要）
///   · 回调在主线程投递，start/stop 也在主线程，无需加锁
///
/// 位置取 `NSEvent.mouseLocation`（AppKit 全局坐标，左下原点，点）——
/// 全局监视器的 `locationInWindow` 是接收窗口坐标，不能直接用。
/// 双击/三击的合并不在这里做 —— 原始事件全部记下，
/// 合并是 `StepDetector.detectSteps(clicks:)` 的纯计算职责。
final class MouseClickTracker {

    private var monitor: Any?
    private let elapsedProvider: () -> Double
    private var events: [ClickEvent] = []

    init(elapsedProvider: @escaping () -> Double) {
        self.elapsedProvider = elapsedProvider
    }

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.record()
        }
    }

    /// 停止监视，返回全部点击事件（净录制时间 + 全局位置）。
    func stop() -> [ClickEvent] {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        return events
    }

    private func record() {
        events.append(ClickEvent(time: elapsedProvider(), location: NSEvent.mouseLocation))
    }
}
