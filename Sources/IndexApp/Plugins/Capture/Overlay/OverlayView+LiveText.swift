import AppKit
import VisionKit

/// 选字（Live Text）在覆盖层里的宿主状态。`container` 与 `overlay` 的挂载由
/// `wantsLiveTextOverlay` 驱动（tool == nil && pointerEngaged），`analysis`
/// 键含选区矩形与马赛克图层。由宿主 `OverlayView` 以组合方式持有，避免把
/// 视图层级与异步任务散在主视图里。
final class LiveTextOverlayHost {
    var container: LiveTextHitTestView?
    var overlay: ImageAnalysisOverlayView?
    /// 键含选区矩形与马赛克图层，任一变了都要重跑分析。
    var analysis: (rect: CGRect, pixelates: Layers<ImageSpace>, task: Task<ImageAnalysis?, Never>)?
    var isActive: Bool { overlay != nil }

    /// 覆盖层整套退出时的最终收尾。普通的 `unmount` 只暂时拆系统视图，保留分析缓存
    /// 供用户再次进入鼠标模式复用；controller dismiss 则必须取消任务并断开所有视图引用。
    func teardown() {
        analysis?.task.cancel()
        analysis = nil
        container?.removeFromSuperview()
        container = nil
        overlay = nil
    }
}

/// 鼠标模式下包住系统选字层的命中测试包装。
///
/// `ImageAnalysisOverlayView` 是 final，没法覆写它的 hitTest，所以在外面包一层，
/// 明确规定选区内事件的归属（自上而下）：
///   1. 命中标注图层 / 缩放控制点 → 返回 nil，事件穿给 `OverlayView`（点图层 = 选图层）
///   2. 命中系统层的可交互文字（`hasInteractiveItem`）→ 交给系统层（拖 = 选字）
///   3. 其余 → 返回 nil，穿给 `OverlayView`（拖空白 = 调整选区）
/// 不依赖系统层自身的穿透行为 —— 无论它吞不吞非文字区域的事件，三种手势都成立。
final class LiveTextHitTestView: NSView {

    /// 返回 true 表示这个点该交还宿主处理（参数是本视图局部坐标）。
    var passesToHost: ((CGPoint) -> Bool)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        // 约定入参在父视图坐标系（NSView.hitTest 的语义）。
        guard let superview else { return nil }
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        if passesToHost?(local) == true { return nil }
        guard let overlay = subviews.first as? ImageAnalysisOverlayView,
              overlay.hasInteractiveItem(at: overlay.convert(local, from: self))
        else { return nil }
        // overlay 的 hitTest 期望父视图（= 本视图）坐标。
        return overlay.hitTest(local) ?? overlay
    }
}

// MARK: - 选字（Live Text）
// 从 OverlayView.swift 拆出，保持行为一致。
extension OverlayView {

    /// 选区确认 / 调整后立即后台预跑分析 —— 等用户进入鼠标模式时结果多半已经就绪。
    /// 幂等：键（选区矩形 + 马赛克图层）没变就直接复用在跑 / 跑完的任务。
    /// 键盘扩展（方向键微调）也要调，所以不是 private。
    func prepareLiveTextAnalysis() {
        guard LiveTextAnalyzer.isSupported, mode == .capture, !finishOnConfirm,
              model.phase == .confirmed, let rect = model.confirmedRect else { return }
        let pixelates = annotation.exportLayers(
            selection: geometry.annotationRect(fromGlobal: rect),
            scale: model.snapshot.scale
        ).filter { $0.kind == .pixelate }
        if let cached = liveTextHost.analysis, cached.rect == rect, cached.pixelates == pixelates {
            return
        }
        guard let crop = model.makeCroppedImage() else { return }
        liveTextHost.analysis?.task.cancel()
        let image = pixelates.isEmpty ? crop : LayerRenderer.render(base: crop, layers: pixelates)
        liveTextHost.analysis = (rect, pixelates, Task { await LiveTextAnalyzer.analyze(image) })
    }

    /// 鼠标模式（tool == nil && pointerEngaged）下应当挂着系统选字层。
    var wantsLiveTextOverlay: Bool {
        LiveTextAnalyzer.isSupported && mode == .capture && !finishOnConfirm
            && model.phase == .confirmed
            && annotation.tool == nil && annotation.pointerEngaged
    }

    /// 让选字层的挂载状态与鼠标模式对齐。
    func syncLiveTextOverlay() {
        wantsLiveTextOverlay ? mountLiveTextOverlay() : unmountLiveTextOverlay()
    }

    func mountLiveTextOverlay() {
        guard liveTextHost.overlay == nil, let rect = model.confirmedRect else { return }
        prepareLiveTextAnalysis()
        let overlay = ImageAnalysisOverlayView()
        overlay.preferredInteractionTypes = [.textSelection]
        let container = LiveTextHitTestView(frame: geometry.viewLocal(fromGlobal: rect))
        overlay.frame = container.bounds
        overlay.autoresizingMask = [.width, .height]
        container.addSubview(overlay)
        container.passesToHost = { [weak self, weak container] point in
            guard let self, let container else { return false }
            let local = self.convert(point, from: container)
            if self.slots.contains(where: { $0.control != nil && $0.hitFrame.contains(local) }) {
                return true
            }
            let canvas = self.geometry.annotationPoint(fromViewLocal: local)
            return self.annotation.resizeHandle(at: canvas) != nil
                || self.annotation.layer(at: canvas) != nil
        }
        addSubview(container)
        liveTextHost.container = container
        liveTextHost.overlay = overlay
        applyLiveTextAnalysis()
        redraw()
    }

    func unmountLiveTextOverlay() {
        guard liveTextHost.overlay != nil else { return }
        liveTextHost.container?.removeFromSuperview()
        liveTextHost.container = nil
        liveTextHost.overlay = nil
        window?.makeFirstResponder(self)
        redraw()
    }

    /// SelectionOverlayController dismiss 时调用；与临时退出鼠标模式的 unmount 分开。
    func teardownLiveText() {
        liveTextHost.teardown()
    }

    /// 选区被微调 / 拖动后，把选字层贴回新位置并套用按新选区重跑的分析。
    func syncLiveTextOverlayFrame() {
        guard let container = liveTextHost.container, let rect = model.confirmedRect else { return }
        container.frame = geometry.viewLocal(fromGlobal: rect)
        applyLiveTextAnalysis()
    }

    private func applyLiveTextAnalysis() {
        let task = liveTextHost.analysis?.task
        let overlay = liveTextHost.overlay
        Task { [weak self, weak overlay] in
            let analysis = await task?.value
            guard let self, let overlay, overlay === self.liveTextHost.overlay else { return }
            overlay.analysis = analysis
        }
    }

    /// 鼠标模式下的 ⌘C：有选中文字就复制文字（而不是整张图）。返回是否已处理。
    func copyLiveTextSelection() -> Bool {
        guard let overlay = liveTextHost.overlay, overlay.hasActiveTextSelection else { return false }
        Clipboard.copy(text: overlay.selectedText)
        return true
    }

    /// 选字层里有选中的文字时清掉它 —— 右键退出链的第一级。返回是否已处理。
    func clearLiveTextSelection() -> Bool {
        guard let overlay = liveTextHost.overlay, overlay.hasActiveTextSelection else { return false }
        overlay.resetSelection()
        return true
    }
}
