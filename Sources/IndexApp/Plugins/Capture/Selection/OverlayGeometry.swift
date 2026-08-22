import AppKit

/// 覆盖层里三套坐标系之间的换算，集中在一处。
///
/// 混用坐标系是这类项目最大的 bug 来源，所以宁可多一层显式转换，也不在事件处理里就地算：
///   · 视图局部    左下原点，Y 向上（NSView 的绘制与事件坐标）
///   · AppKit 全局 主屏左下原点（选区、窗口 frame 都用它）
///   · 标注空间    显示器局部、左上原点、Y 向下（标注图层与 LayerRenderer 的约定）
struct OverlayGeometry {

    /// 视图边界（点）。
    let bounds: CGRect
    /// 该显示器在 AppKit 全局坐标里的原点。
    let displayOrigin: CGPoint

    func global(fromViewLocal point: CGPoint) -> CGPoint {
        CGPoint(x: point.x + displayOrigin.x, y: point.y + displayOrigin.y)
    }

    func viewLocal(fromGlobal rect: CGRect) -> CGRect {
        CGRect(
            x: rect.origin.x - displayOrigin.x,
            y: rect.origin.y - displayOrigin.y,
            width: rect.width,
            height: rect.height
        )
    }

    func annotationPoint(fromViewLocal point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: bounds.height - point.y)
    }

    func annotationRect(fromGlobal rect: CGRect) -> CGRect {
        let local = viewLocal(fromGlobal: rect)
        return CGRect(
            x: local.minX,
            y: bounds.height - local.maxY,
            width: local.width,
            height: local.height
        )
    }
}
