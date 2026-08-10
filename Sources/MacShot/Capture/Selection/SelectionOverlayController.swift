import AppKit

/// 选区层的交互形态。
enum SelectionMode {
    /// 截图：确认选区后出动作工具条 + 标注工具。
    case capture
    /// 只拿一个矩形（录屏选区用）：无工具条、无标注，回车 / 双击选区返回。
    case plain
}

/// 覆盖所有显示器的选区层。
///
/// 只负责：建窗口、分发选区结果、协调多屏之间的互斥。
@MainActor
final class SelectionOverlayController {

    private var windows: [OverlayWindow] = []
    private var views: [OverlayView] = []
    private var completion: ((SelectionResult?) -> Void)?

    var isActive: Bool { !windows.isEmpty }

    /// - Parameters:
    ///   - snapshots: 每块屏的冻结画面，必须在覆盖层出现**之前**拍好。
    ///   - finishOnConfirm: 简单模式 —— 松手（或单击窗口）确认选区后立刻返回，
    ///     不显示工具条、不进标注阶段。滚动截图用它只拿 region + display。
    func begin(
        snapshots: [DisplaySnapshot],
        windowList: [WindowInfo],
        mode: SelectionMode = .capture,
        finishOnConfirm: Bool = false,
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
            let view = OverlayView(
                model: model,
                isPrimaryScreen: snapshot.display.id == primaryID,
                mode: mode
            )
            view.finishOnConfirm = finishOnConfirm
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
