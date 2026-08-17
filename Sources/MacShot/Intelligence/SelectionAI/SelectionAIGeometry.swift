import CoreGraphics

/// 三个画布宿主共用的选区几何。调用方先把鼠标位置转换成图像像素坐标，之后的
/// 反向拖拽、边界截断和像素取整只在这里实现一次。
enum SelectionAIGeometry {
    static func isUsableBounds(_ bounds: CGRect) -> Bool {
        !bounds.isNull && !bounds.isInfinite && bounds.width > 0 && bounds.height > 0
    }

    static func clamped(_ point: CGPoint, to bounds: CGRect) -> CGPoint? {
        guard isUsableBounds(bounds) else { return nil }
        let bounds = bounds.standardized
        return CGPoint(
            x: min(max(point.x, bounds.minX), bounds.maxX),
            y: min(max(point.y, bounds.minY), bounds.maxY)
        )
    }

    /// 拖拽中的预览矩形保持小数像素，避免缩放画布上移动时跳格。
    static func previewRect(from anchor: CGPoint, to point: CGPoint, within bounds: CGRect) -> CGRect? {
        guard let anchor = clamped(anchor, to: bounds),
              let point = clamped(point, to: bounds)
        else { return nil }

        return CGRect(
            x: min(anchor.x, point.x),
            y: min(anchor.y, point.y),
            width: abs(point.x - anchor.x),
            height: abs(point.y - anchor.y)
        )
    }

    /// 松手时扩到完整像素并重新与图像边界相交。过小区域回 nil，避免一次轻点就把
    /// 几个像素误送给模型。
    static func finalizedRect(
        from anchor: CGPoint,
        to point: CGPoint,
        within bounds: CGRect,
        minimumSide: CGFloat
    ) -> CGRect? {
        guard let preview = previewRect(from: anchor, to: point, within: bounds) else {
            return nil
        }
        let bounds = bounds.standardized
        let integral = preview.integral.intersection(bounds)
        guard !integral.isNull,
              integral.width >= max(1, minimumSide),
              integral.height >= max(1, minimumSide)
        else { return nil }
        return integral
    }
}
