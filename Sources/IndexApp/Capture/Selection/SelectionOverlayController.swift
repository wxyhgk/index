import AppKit

/// 选区层的交互形态。
enum SelectionMode {
    /// 截图：确认选区后出动作工具条 + 标注工具。
    case capture
    /// 只拿一个矩形（录屏选区用）：无工具条、无标注，回车 / 双击选区返回。
    case plain
}

/// 覆盖同一次拓扑快照里的全部显示器。
///
/// 只负责：建窗口、分发选区结果、协调多屏之间的互斥。
@MainActor
final class SelectionOverlayController {

    private var windows: [OverlayWindow] = []
    private var views: [OverlayView] = []
    private var completion: ((SelectionResult?) -> Void)?
    private let selectionAIExecutorFactory: @MainActor () -> SelectionAIExecutor
    /// 覆盖层视图的设置切片（放大镜 / 回车语义 / 标注样式）。注入式。
    private let capture: any CapturePreferences
    private let annotationStyle: any AnnotationStylePreferences

    init(
        capture: any CapturePreferences,
        annotationStyle: any AnnotationStylePreferences,
        selectionAIExecutorFactory: @escaping @MainActor () -> SelectionAIExecutor = {
            SelectionAIExecutor()
        }
    ) {
        self.capture = capture
        self.annotationStyle = annotationStyle
        self.selectionAIExecutorFactory = selectionAIExecutorFactory
    }

    var isActive: Bool { !windows.isEmpty }

    /// - Parameters:
    ///   - snapshots: 目标屏幕的冻结画面，必须在覆盖层出现**之前**拍好。
    ///   - finishOnConfirm: 简单模式 —— 松手（或单击窗口）确认选区后立刻返回，
    ///     不显示工具条、不进标注阶段。滚动截图用它只拿 region + display。
    @discardableResult
    func begin(
        snapshots: [DisplaySnapshot],
        windowList: [WindowInfo],
        mode: SelectionMode = .capture,
        finishOnConfirm: Bool = false,
        completion: @escaping (SelectionResult?) -> Void
    ) -> Bool {
        guard !isActive, !snapshots.isEmpty else { return false }

        // 捕获完成到覆盖层出现之间也可能刚好接入/断开 Sidecar。严格核对整套
        // displayID + frame + scale，禁止跳过某一屏后继续展示半套覆盖层。
        let currentScreens = NSScreen.screens
        let currentDisplays = currentScreens.compactMap(DisplayInfo.init(screen:))
        let frozenDisplays = snapshots.map(\.display)
        guard DisplayTopology.matches(frozenDisplays, currentDisplays) else {
            NSLog(
                "[Index] 覆盖层拒绝陈旧拓扑 frozen=%@ current=%@",
                frozenDisplays.map { "\($0.name)(\($0.id))" }.joined(separator: ", "),
                currentDisplays.map { "\($0.name)(\($0.id))" }.joined(separator: ", ")
            )
            return false
        }

        let screensByID = Dictionary(uniqueKeysWithValues: currentScreens.compactMap { screen in
            Geometry.displayID(of: screen).map { ($0, screen) }
        })
        guard snapshots.allSatisfy({ screensByID[$0.display.id] != nil }) else {
            return false
        }

        self.completion = completion

        let primaryID = NSScreen.main.flatMap(Geometry.displayID(of:))
        // 同一次多屏覆盖层共享严格单飞门：即使焦点在屏之间切换，也不能并发
        // 向同一 Provider 扇出两个选区请求。
        let selectionAIExecutor = selectionAIExecutorFactory()

        for snapshot in snapshots {
            guard let screen = screensByID[snapshot.display.id] else { continue }

            let model = SelectionModel(snapshot: snapshot, windows: windowList)
            let view = OverlayView(
                model: model,
                isPrimaryScreen: snapshot.display.id == primaryID,
                mode: mode,
                capture: capture,
                annotationStyle: annotationStyle,
                selectionAIExecution: OverlaySelectionAIExecution(executor: selectionAIExecutor)
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
        return true
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
        views.forEach { $0.clearToolbarToolTips() }
        views.forEach {
            $0.teardownSelectionAI()
            $0.teardownLiveText()
        }
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        views.removeAll()
    }
}
