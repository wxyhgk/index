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
    /// 最近一次交互所在的屏。跨屏选区的状态从它广播到其余屏。
    private weak var activeView: OverlayView?
    /// 本次捕获的冻结画面，跨屏输出时用于拼接。
    private var snapshots: [DisplaySnapshot] = []
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
        self.snapshots = snapshots

        let primaryID = NSScreen.main.flatMap(Geometry.displayID(of:))
        // 同一次多屏覆盖层共享严格单飞门：即使焦点在屏之间切换，也不能并发
        // 向同一 Provider 扇出两个选区请求。
        let selectionAIExecutor = selectionAIExecutorFactory()
        // A 的坐标模型：所有屏共用同一个虚拟桌面包围盒；每屏 model 仍保留
        // 自己的 display frame 用于绘制与局部坐标换算。
        let selectionBounds = snapshots
            .map(\.display.frame)
            .reduce(CGRect.null) { $0.union($1) }

        for snapshot in snapshots {
            guard let screen = screensByID[snapshot.display.id] else { continue }

            let model = SelectionModel(
                snapshot: snapshot,
                windows: windowList,
                selectionBounds: selectionBounds
            )
            let view = OverlayView(
                model: model,
                isPrimaryScreen: snapshot.display.id == primaryID,
                mode: mode,
                capture: capture,
                annotationStyle: annotationStyle,
                selectionAIExecution: OverlaySelectionAIExecution(executor: selectionAIExecutor)
            )
            view.finishOnConfirm = finishOnConfirm
            view.buildCrossDisplayResult = { [weak self, weak view] actionID in
                guard let self, let view else { return nil }
                return self.buildCrossDisplayResult(from: view, actionID: actionID)
            }
            view.buildRenderedPreview = { [weak self, weak view] in
                guard let self, let view else { return nil }
                return self.renderFramePreview(from: view)
            }
            view.onFinish = { [weak self] result in self?.finish(result) }
            view.onSelectionEnded = { [weak self, weak view] in
                guard let self, let view else { return }
                // 只有跨屏选区才需要把工具栏切到指针所在屏；单屏保持原行为。
                // 壳属于每个 overlay 自己的 AnnotationState：开壳时先不切屏，
                // 否则新活动屏没有壳层，工具栏会显示成关闭。
                guard !view.annotation.hasEffect(.frame),
                      let region = view.model.confirmedRect,
                      self.snapshots.filter({ $0.display.frame.intersects(region) }).count > 1
                else { return }
                let mouse = NSEvent.mouseLocation
                let target = self.views.first {
                    $0.window?.frame.intersects(region) == true
                        && $0.window?.frame.contains(mouse) == true
                } ?? view
                guard target !== self.activeView else { return }
                // 目标屏可能是非活动屏；先把刚确认的选区同步过去，再交棒。
                target.model.adoptSelection(from: view.model)
                self.activeView = target
                self.views.forEach { $0.setInactive($0 !== target) }
                self.broadcastSelection(from: target, force: true)
            }
            view.onSelectionChanged = { [weak self, weak view] in
                guard let self, let view else { return }
                self.broadcastSelection(from: view)
            }
            view.onBecameActive = { [weak self] owner in
                guard let self else { return }
                // 一次只允许一块屏处于活动状态；其它屏保留同一份选区用于绘制。
                self.activeView = owner
                self.views.forEach { $0.setInactive($0 !== owner) }
                self.broadcastSelection(from: owner, force: true)
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
        if let index = windows.firstIndex(where: { $0 === preferred }) {
            activeView = views[index]
            views.forEach { $0.setInactive($0 !== views[index]) }
        }

        NSApp.activate(ignoringOtherApps: true)
        NSCursor.crosshair.push()
        return true
    }

    /// 跨屏输出：拼接所有相交的冻结画面，并把每块屏的标注按各自裁剪偏移合并。
    private func buildCrossDisplayResult(
        from view: OverlayView,
        actionID: String
    ) -> SelectionResult? {
        guard view.model.phase == .confirmed,
              let region = view.model.confirmedRect
        else { return nil }

        let intersecting = snapshots.filter { $0.display.frame.intersects(region) }
        guard intersecting.count > 1 else { return nil }

        NSLog(
            "[Index] 跨屏截图 region=%@ displays=%@",
            NSStringFromRect(region),
            intersecting.map { $0.display.name }.joined(separator: ", ")
        )
        let scale = view.model.snapshot.scale
        let activeIntersection = view.model.snapshot.frame.intersection(region)

        // 录屏 / 长截图只支持单屏：把 region 收敛到活动屏，避免把跨屏矩形
        // 交给只认识单 display 的录制器。
        if actionID == ActionID.record
            || actionID == ActionID.scrollCapture
            || actionID == ActionID.gifCapture {
            guard let image = view.model.snapshot.crop(globalRect: activeIntersection) else {
                return nil
            }
            return SelectionResult(
                region: activeIntersection,
                display: view.model.snapshot.display,
                window: nil,
                actionID: actionID,
                image: image,
                layers: Layers<ImageSpace>(),
                windowCaptureRequest: nil
            )
        }

        guard let image = MultiDisplayComposer.stitch(
            region: region,
            snapshots: intersecting,
            outputScale: scale
        ) else { return nil }

        let layers = Layers<ImageSpace>(
            views.flatMap { $0.exportAnnotationLayers(for: region, scale: scale).elements }
        )

        return SelectionResult(
            region: region,
            display: view.model.snapshot.display,
            window: nil,
            actionID: actionID,
            image: image,
            layers: layers,
            windowCaptureRequest: nil
        )
    }

    /// 带壳预览的成品图：单屏直接裁，跨屏先拼接，再把所有屏的标注合并进去。
    private func renderFramePreview(from view: OverlayView) -> CGImage? {
        guard let region = view.model.confirmedRect else { return nil }
        let intersecting = snapshots.filter { $0.display.frame.intersects(region) }
        guard !intersecting.isEmpty else { return nil }
        let scale = view.model.snapshot.scale

        let base: CGImage?
        let layers: Layers<ImageSpace>
        if intersecting.count > 1 {
            base = MultiDisplayComposer.stitch(
                region: region,
                snapshots: intersecting,
                outputScale: scale
            )
            layers = Layers<ImageSpace>(
                views.flatMap { $0.exportAnnotationLayers(for: region, scale: scale).elements }
            )
        } else {
            base = view.model.makeCroppedImage()
            layers = view.annotation.exportLayers(
                selection: view.geometry.annotationRect(fromGlobal: region),
                scale: scale
            )
        }
        guard let base else { return nil }
        return LayerRenderer.render(base: base, layers: layers)
    }

    /// 活动屏每次重绘后，把全局选区同步给其它屏；其它屏只重绘，不回写。
    private func broadcastSelection(from source: OverlayView, force: Bool = false) {
        guard let activeView, source === activeView else { return }
        for view in views where view !== source {
            let changed = view.model.adoptSelection(from: source.model)
            if changed || force {
                view.redrawFromSharedSelection()
            }
        }
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
