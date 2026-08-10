import AppKit
import VisionKit

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
        if let cached = liveTextAnalysis, cached.rect == rect, cached.pixelates == pixelates {
            return
        }
        guard let crop = model.makeCroppedImage() else { return }
        liveTextAnalysis?.task.cancel()
        let image = pixelates.isEmpty ? crop : LayerRenderer.render(base: crop, layers: pixelates)
        liveTextAnalysis = (rect, pixelates, Task { await LiveTextAnalyzer.analyze(image) })
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
        guard liveTextOverlay == nil, let rect = model.confirmedRect else { return }
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
            if self.slots.contains(where: { $0.control != nil && $0.frame.contains(local) }) {
                return true
            }
            let canvas = self.geometry.annotationPoint(fromViewLocal: local)
            return self.annotation.resizeHandle(at: canvas) != nil
                || self.annotation.layer(at: canvas) != nil
        }
        addSubview(container)
        liveTextContainer = container
        liveTextOverlay = overlay
        applyLiveTextAnalysis()
        redraw()
    }

    func unmountLiveTextOverlay() {
        guard liveTextOverlay != nil else { return }
        liveTextContainer?.removeFromSuperview()
        liveTextContainer = nil
        liveTextOverlay = nil
        window?.makeFirstResponder(self)
        redraw()
    }

    /// 选区被微调 / 拖动后，把选字层贴回新位置并套用按新选区重跑的分析。
    func syncLiveTextOverlayFrame() {
        guard let container = liveTextContainer, let rect = model.confirmedRect else { return }
        container.frame = geometry.viewLocal(fromGlobal: rect)
        applyLiveTextAnalysis()
    }

    private func applyLiveTextAnalysis() {
        let task = liveTextAnalysis?.task
        Task { [weak self, weak overlay = liveTextOverlay] in
            let analysis = await task?.value
            guard let self, let overlay, overlay === self.liveTextOverlay else { return }
            overlay.analysis = analysis
        }
    }

    /// 鼠标模式下的 ⌘C：有选中文字就复制文字（而不是整张图）。返回是否已处理。
    func copyLiveTextSelection() -> Bool {
        guard let overlay = liveTextOverlay, overlay.hasActiveTextSelection else { return false }
        Clipboard.copy(text: overlay.selectedText)
        return true
    }

    /// 选字层里有选中的文字时清掉它 —— Esc / 右键退出链的第一级。返回是否已处理。
    func clearLiveTextSelection() -> Bool {
        guard let overlay = liveTextOverlay, overlay.hasActiveTextSelection else { return false }
        overlay.resetSelection()
        return true
    }
}
