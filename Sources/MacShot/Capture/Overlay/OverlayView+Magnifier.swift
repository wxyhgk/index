import AppKit

extension OverlayView {

    /// 只在「正在挑位置」时显示：确认之后画面已经定了，放大镜只会挡住工具条。
    var magnifierPayload: (sample: PixelSample, cursor: CGPoint)? {
        guard AppSettings.shared.showMagnifier, !model.isInactive else { return nil }
        switch model.phase {
        case .idle, .dragging, .adjusting:
            guard let cursor, let cursorSample else { return nil }
            return (cursorSample, cursor)
        case .confirmed:
            return nil
        }
    }

    /// 光标一动就重新采样。采的是一小块（21×21 像素）+ 单个像素，都是内存操作。
    func updateCursor(_ local: CGPoint) {
        guard AppSettings.shared.showMagnifier else {
            if cursor != nil { cursor = nil; cursorSample = nil }
            return
        }
        cursor = local
        cursorSample = model.snapshot.sample(aroundGlobal: geometry.global(fromViewLocal: local))
    }
}
