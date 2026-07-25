import AppKit

/// 覆盖所有显示器的选区层。
///
/// 只负责：建窗口、分发选区结果、协调多屏之间的互斥。
@MainActor
final class SelectionOverlayController {

    private var windows: [OverlayWindow] = []
    private var views: [OverlayView] = []
    private var completion: ((SelectionResult?) -> Void)?

    var isActive: Bool { !windows.isEmpty }

    /// - Parameter snapshots: 每块屏的冻结画面，必须在覆盖层出现**之前**拍好。
    func begin(
        snapshots: [DisplaySnapshot],
        windowList: [WindowInfo],
        completion: @escaping (SelectionResult?) -> Void
    ) {
        guard !isActive, !snapshots.isEmpty else { return }
        self.completion = completion

        let primaryID = NSScreen.main.flatMap(Geometry.displayID(of:))

        for snapshot in snapshots {
            guard let screen = NSScreen.screens.first(where: {
                Geometry.displayID(of: $0) == snapshot.display.id
            }) else { continue }

            let model = SelectionModel(snapshot: snapshot, windows: windowList)
            let view = OverlayView(model: model, isPrimaryScreen: snapshot.display.id == primaryID)
            view.onFinish = { [weak self] result in self?.finish(result) }
            view.onBecameActive = { [weak self] owner in
                // 一次只允许一块屏处于活动状态。
                self?.views.forEach { $0.setInactive($0 !== owner) }
            }

            let window = OverlayWindow(screen: screen)
            window.contentView = view
            window.orderFrontRegardless()
            windows.append(window)
            views.append(view)
        }

        // 鼠标当前所在的那块屏优先拿 key —— 否则键盘事件会落到别的屏上。
        let mouse = NSEvent.mouseLocation
        let preferred = windows.first { $0.frame.contains(mouse) } ?? windows.first
        preferred?.makeKeyAndOrderFront(nil)

        NSApp.activate(ignoringOtherApps: true)
        NSCursor.crosshair.push()
    }

    private func finish(_ result: SelectionResult?) {
        let handler = completion
        completion = nil
        dismiss()
        handler?(result)
    }

    func dismiss() {
        guard isActive else { return }
        NSCursor.pop()
        NSCursor.arrow.set()
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        views.removeAll()
    }
}
