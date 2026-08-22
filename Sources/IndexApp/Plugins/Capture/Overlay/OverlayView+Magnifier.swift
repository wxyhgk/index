import AppKit

/// 放大镜在覆盖层里的本地状态。存光标位置与像素采样，计算是否该显示。
/// 无 AppKit 依赖之外的可变状态由宿主 `OverlayView` 以组合方式持有，
/// 采样本身仍由 `DisplaySnapshot.sample` 完成。
final class OverlayMagnifierState {
    var cursor: CGPoint?
    var cursorSample: PixelSample?
}

extension OverlayView {

    /// 只在「正在挑位置」时显示：确认之后画面已经定了，放大镜只会挡住工具条。
    var magnifierPayload: (sample: PixelSample, cursor: CGPoint)? {
        guard capture.showMagnifier, !model.isInactive else { return nil }
        switch model.phase {
        case .idle, .dragging, .adjusting:
            guard let cursor = magnifierState.cursor,
                  let cursorSample = magnifierState.cursorSample else { return nil }
            return (cursorSample, cursor)
        case .confirmed:
            return nil
        }
    }

    /// 光标一动就重新采样。采的是一小块（21×21 像素）+ 单个像素，都是内存操作。
    func updateCursor(_ local: CGPoint) {
        guard capture.showMagnifier else {
            if magnifierState.cursor != nil {
                magnifierState.cursor = nil
                magnifierState.cursorSample = nil
            }
            return
        }
        magnifierState.cursor = local
        magnifierState.cursorSample = model.snapshot.sample(
            aroundGlobal: geometry.global(fromViewLocal: local)
        )
    }
}
