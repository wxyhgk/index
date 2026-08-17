import AppKit

// MARK: - 选中图层的拖角缩放
//
// 进行时状态（resizeID / resizeOriginal / …）声明在主文件，
// 写访问为本扩展放开；每帧都从「快照 + 累计位移」重算，不累积浮点误差。

extension AnnotationState {

    /// 命中选中图层的缩放控制点（画布空间）。只对 `selectedID` 生效 ——
    /// 控制点只画在选中层上，未选中的层点到的是图层本体（走 beginMove）。
    /// 热区随 `strokeScale` 缩放，屏幕上恒定约 ±8pt。
    func resizeHandle(at point: CGPoint) -> ResizeHandle? {
        guard let selectedID, let index = layers.firstIndex(id: selectedID) else { return nil }
        let layer = layers[index]
        let radius = 8 * strokeScale
        for handle in ResizeHandle.handles(for: layer.kind) {
            let center = handle.location(of: layer)
            if abs(point.x - center.x) <= radius, abs(point.y - center.y) <= radius {
                return handle
            }
        }
        return nil
    }

    func beginResize(handle: ResizeHandle, at point: CGPoint) {
        guard let selectedID, let index = layers.firstIndex(id: selectedID) else { return }
        resizeID = selectedID
        activeResizeHandle = handle
        resizeOriginal = layers[index]
        resizeStartPoint = point
        resizeFromPreview = pixelatePreviews[selectedID]
    }

    /// 按 kind 的缩放语义，每帧从 beginResize 快照重算：
    ///   · line / arrow：只动被拖的那一端，负宽高合法（standardize 会把箭头方向弄反）
    ///   · counter：保持圆形 —— 拖角取 max(w, h)，拖边取被拖的那一维，对侧锚定不动
    ///   · text：rect 只存锚点，按量出的文字范围缩放，fontSize 随高度比例走
    ///   · dimension：改完 rect 重烤标签（`prepareDimension`，像素数值按新尺寸重算）
    ///   · 其余矩形类：直接改 rect
    @discardableResult
    func updateResize(to point: CGPoint) -> Bool {
        guard let resizeID,
              let handle = activeResizeHandle,
              let original = resizeOriginal,
              let start = resizeStartPoint,
              let index = layers.firstIndex(id: resizeID) else { return false }

        let delta = CGPoint(x: point.x - start.x, y: point.y - start.y)
        guard let descriptor = ToolRegistry.descriptor(for: original.kind) else { return false }
        layers[index] = descriptor.resize(
            original, handle: handle, delta: delta, pixelScale: pixelScale
        )
        return true
    }

    /// 结束缩放。缩没了（小于最小尺寸）整层恢复原样、不入栈；
    /// 马赛克按新矩形重裁贴片（同 `endMove`）。撤销记录：
    /// 马赛克走 `.move`（它带贴片快照，style 不带），其余整层快照走 `.style`。
    /// - Parameter pixelSource: 和 `endDraw` 的同名参数一致。
    @discardableResult
    func endResize(pixelSource: (CGRect) -> CGImage?) -> Bool {
        defer {
            resizeID = nil
            activeResizeHandle = nil
            resizeOriginal = nil
            resizeStartPoint = nil
            resizeFromPreview = nil
        }
        guard let resizeID,
              let original = resizeOriginal,
              let index = layers.firstIndex(id: resizeID) else { return false }
        let layer = layers[index]

        if !Self.meetsMinimumSize(layer) {
            layers[index] = original
            if original.kind == .pixelate { pixelatePreviews[resizeID] = resizeFromPreview }
            return true
        }
        // 原地点了一下没有变化，不算一次操作。
        guard layer != original else { return true }

        if layer.kind == .pixelate {
            pixelatePreviews[resizeID] = pixelSource(layer.rect.cg).flatMap { LayerRenderer.pixelated($0, blockScale: layer.blockScale ?? 1) }
            history.record(.move(
                id: resizeID,
                from: original.rect,
                to: layer.rect,
                oldPreview: resizeFromPreview,
                newPreview: pixelatePreviews[resizeID]
            ))
        } else {
            history.record(.style(id: resizeID, before: original, after: layer))
        }
        return true
    }

    /// 缩到多小算「缩没了」由各工具自己定（线段看长度、文字看字号、
    /// 测量允许单维为 0 的吸附形态）。效果层不参与缩放，一律放行。
    private static func meetsMinimumSize(_ layer: Layer) -> Bool {
        ToolRegistry.descriptor(for: layer.kind)?.meetsMinimumSize(layer) ?? true
    }
}