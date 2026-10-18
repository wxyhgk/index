import AppKit
import CoreGraphics

/// 多边形选区绘制中状态（AppKit 全局坐标，左下原点）。
struct PolygonState {
    /// 已确认顶点。
    var points: [CGPoint] = []
    /// 当前鼠标位置（预览线段终点）。
    var previewPoint: CGPoint?
    /// 鼠标吸附到第一个顶点（闭合辅助，≥ 3 点）。
    var snapToFirst = false
    /// mouseDown 位置（第一个点放置前的预览起点）。
    var segmentStart: CGPoint?

    /// 预览线段起点：最后一个已确认顶点。没有点时为 nil（不画虚线）。
    var previewStart: CGPoint? { points.last }
}

/// 单块显示器上的选区状态机。
///
/// 纯逻辑，不碰绘制、不碰事件循环、不持有视图 —— 所有输入都是全局坐标点，
/// 所有输出都是可查询的属性。视图只负责把鼠标事件翻译成这里的方法调用。
@MainActor
final class SelectionModel {

    enum Phase {
        case idle          // 等待拖拽 / 悬停窗口
        case dragging      // 正在画新选区
        case confirmed     // 选区已定，可调整、可选择操作
        case adjusting     // 正在拖控制点或整体移动
    }

    /// 选区的 8 个调整控制点，外加「内部」用于整体拖动。
    /// 几何实现提到了 `ResizeHandle`（与标注图层的拖角缩放共享同一套
    /// 翻转/位移逻辑），这里保留原名引用，行为零变化。
    typealias Handle = ResizeHandle

    let snapshot: DisplaySnapshot

    private let windows: [WindowInfo]
    /// 拖拽小于这个距离视为「点击」，走整窗选择。
    private let dragThreshold: CGFloat = 6
    /// 控制点的命中半径（点）。比视觉尺寸大一圈，小选区也好抓。
    private let handleHitRadius: CGFloat = 9
    private let minimumSize: CGFloat = 8
    /// 窗口吸附阈值（点）。选区边缘距窗口边 ≤ 此值时自动吸附。
    private let snapThreshold: CGFloat = 5

    /// 选区的四个角（圆角控制点用）。
    enum Corner: CaseIterable, Equatable {
        case topLeft, topRight, bottomLeft, bottomRight
    }

    /// 圆角半径（点）。0 = 直角。
    private(set) var cornerRadius: CGFloat = 0
    /// 正在调整圆角的角。nil = 未在调整。
    private(set) var adjustingCorner: Corner?

    /// 窗口吸附参考线（渲染用）。
    struct SelectionGuide: Equatable {
        let isHorizontal: Bool
        let position: CGFloat  // AppKit 全局坐标
    }

    private(set) var phase: Phase = .idle
    private(set) var hoveredWindow: WindowInfo?
    private(set) var confirmedRect: CGRect?
    private(set) var confirmedWindow: WindowInfo?
    /// 多边形选区顶点（AppKit 全局坐标，左下原点）。nil = 矩形选区。
    private(set) var confirmedPolygon: [CGPoint]?
    private(set) var guides: [SelectionGuide] = []
    /// 别的屏已经在操作了，这块屏只保留压暗。
    private(set) var isInactive = false

    private var dragOrigin: CGPoint?
    private var dragCurrent: CGPoint?

    private var activeHandle: Handle?
    /// 覆盖层判断是否为整体平移（`inside`）时用 —— `activeHandle` 私有，暴露只读。
    var adjustingHandle: Handle? { activeHandle }
    private var adjustAnchorRect: CGRect?
    private var adjustStartPoint: CGPoint?
    /// 多边形选区绘制中状态。nil = 非多边形模式。
    private(set) var polygon: PolygonState?
    /// 正在拖拽的已确认多边形顶点索引（confirmed 状态下）。nil = 无。
    private(set) var adjustingPolygonVertex: Int?
    /// 多边形顶点命中/吸附半径（点）。
    static let polygonHitRadius: CGFloat = 10

    init(snapshot: DisplaySnapshot, windows: [WindowInfo]) {
        self.snapshot = snapshot
        self.windows = windows
    }

    var bounds: CGRect { snapshot.frame }

    // MARK: - 派生状态

    private var draggingRect: CGRect? {
        guard let a = dragOrigin, let b = dragCurrent else { return nil }
        return CGRect(
            x: min(a.x, b.x),
            y: min(a.y, b.y),
            width: abs(b.x - a.x),
            height: abs(b.y - a.y)
        ).intersection(bounds)
    }

    /// 当前应该高亮的矩形（AppKit 全局坐标）。
    var activeRect: CGRect? {
        if let confirmedRect { return confirmedRect }
        if isPolygonMode {
            if let pts = polygon?.points, pts.count >= 2 {
                let bbox = pts.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }
                if !bbox.isEmpty { return bbox.intersection(bounds) }
            }
            return bounds
        }
        if let draggingRect { return draggingRect }
        guard !isInactive, phase == .idle else { return nil }
        return hoveredWindow?.frame.intersection(bounds)
    }

    /// 高亮的是「悬停到的窗口」而非用户画出来的选区 —— 用来区分蓝框和白框。
    var isWindowHint: Bool {
        phase == .idle && confirmedRect == nil && !isPolygonMode
    }

    /// 选区已定，可以显示控制点（多边形选区用顶点控制点代替矩形控制点）。
    var showsHandles: Bool {
        (phase == .confirmed || phase == .adjusting) && confirmedRect != nil && confirmedPolygon == nil
    }

    /// 多边形选区已定，可以显示顶点控制点。
    var showsPolygonVertices: Bool {
        (phase == .confirmed || phase == .adjusting) && confirmedPolygon != nil
    }

    // MARK: 圆角控制点（单个，固定在选区左上角内侧）

    /// 手柄命中半径（点）。比视觉大一圈，好抓。
    private let cornerHandleHitRadius: CGFloat = 12
    /// 手柄距选区左上角的内缩距离；小选区按比例缩小，保证永远在选区内。
    private func cornerHandleInset(in rect: CGRect) -> CGFloat {
        min(22, max(8, min(rect.width, rect.height) / 3))
    }

    /// 手柄中心（全局坐标，AppKit Y 向上：视觉左上角是 (minX, maxY)）。
    func cornerHandlePoint(in rect: CGRect) -> CGPoint {
        let inset = cornerHandleInset(in: rect)
        return CGPoint(x: rect.minX + inset, y: rect.maxY - inset)
    }

    /// 只剩一个手柄；为兼容调用方仍返回 `.topLeft`。
    func cornerControl(at global: CGPoint) -> Corner? {
        guard showsHandles,
              let rect = confirmedRect,
              rect.width >= 40, rect.height >= 40
        else { return nil }
        let center = cornerHandlePoint(in: rect)
        let dx = global.x - center.x
        let dy = global.y - center.y
        return dx * dx + dy * dy <= cornerHandleHitRadius * cornerHandleHitRadius ? .topLeft : nil
    }

    /// 拖拽起点与起始半径：用增量而不是绝对距离，抓住手柄时半径不会跳。
    private var cornerAdjustStartRadius: CGFloat = 0
    private var cornerAdjustStartPoint: CGPoint = .zero

    func beginCornerAdjust(_ corner: Corner, at global: CGPoint) {
        adjustingCorner = corner
        cornerAdjustStartRadius = cornerRadius
        cornerAdjustStartPoint = global
    }

    @discardableResult
    func updateCornerAdjust(to global: CGPoint) -> Bool {
        guard adjustingCorner != nil, let rect = confirmedRect else { return false }
        let dx = global.x - cornerAdjustStartPoint.x
        let dy = global.y - cornerAdjustStartPoint.y
        // 手柄在左上角内侧：向左/向上拖 = 增大圆角。投影到对角线，斜拖也跟手。
        let outward = (-dx + dy) / CGFloat(2).squareRoot()
        let maxRadius = max(0, min(rect.width, rect.height) / 2 - 1)
        cornerRadius = max(0, min(cornerAdjustStartRadius + outward, maxRadius))
        return true
    }

    func endCornerAdjust() {
        adjustingCorner = nil
    }

    /// 双击 / 滚轮 / 快捷键入口。返回是否真的改变。
    @discardableResult
    func setCornerRadius(_ value: CGFloat) -> Bool {
        guard showsHandles, let rect = confirmedRect else { return false }
        let maxRadius = max(0, min(rect.width, rect.height) / 2 - 1)
        let clamped = max(0, min(value, maxRadius))
        guard abs(clamped - cornerRadius) > 0.01 else { return false }
        cornerRadius = clamped
        return true
    }

    @discardableResult
    func adjustCornerRadius(by delta: CGFloat) -> Bool {
        setCornerRadius(cornerRadius + delta)
    }

    // MARK: - 命中测试

    /// 返回全局坐标点命中的控制点；不在选区上则返回 nil。
    func handle(at global: CGPoint) -> Handle? {
        guard showsHandles, let rect = confirmedRect else { return nil }

        for handle in Handle.resizeHandles {
            let center = handle.point(in: rect)
            if abs(global.x - center.x) <= handleHitRadius,
               abs(global.y - center.y) <= handleHitRadius {
                return handle
            }
        }
        return rect.contains(global) ? .inside : nil
    }

    // MARK: - 输入（返回值表示是否需要重绘）

    @discardableResult
    func setInactive(_ value: Bool) -> Bool {
        guard isInactive != value else { return false }
        isInactive = value
        if value { reset() }
        return true
    }

    @discardableResult
    func hover(at global: CGPoint) -> Bool {
        guard !isInactive, phase == .idle else { return false }
        let hit = windows.first { $0.frame.contains(global) }
        guard hit?.windowID != hoveredWindow?.windowID else { return false }
        hoveredWindow = hit
        return true
    }

    // MARK: 画新选区

    func beginDrag(at global: CGPoint) {
        confirmedRect = nil
        confirmedWindow = nil
        isInactive = false
        cornerRadius = 0
        dragOrigin = global
        dragCurrent = global
        phase = .dragging
    }

    @discardableResult
    func updateDrag(to global: CGPoint, shiftPressed: Bool = false) -> Bool {
        guard phase == .dragging, let origin = dragOrigin else { return false }
        var point = global
        // Shift 约束正方形：取两轴绝对值较大者作为边长，保留方向。
        if shiftPressed {
            let dx = global.x - origin.x
            let dy = global.y - origin.y
            let side = max(abs(dx), abs(dy))
            point = CGPoint(
                x: origin.x + (dx >= 0 ? side : -side),
                y: origin.y + (dy >= 0 ? side : -side)
            )
        }
        dragCurrent = point
        return true
    }

    /// 结束拖拽。返回是否成功进入 confirmed。
    @discardableResult
    func endDrag() -> Bool {
        guard phase == .dragging, let origin = dragOrigin, let current = dragCurrent else {
            return false
        }
        defer {
            dragOrigin = nil
            dragCurrent = nil
        }

        let travelled = hypot(current.x - origin.x, current.y - origin.y)
        if travelled < dragThreshold {
            // 位移太小 → 当成点击，选中光标下的窗口
            guard let window = windows.first(where: { $0.frame.contains(current) }) else {
                phase = .idle
                return false
            }
            confirmedRect = window.frame.intersection(bounds)
            confirmedWindow = window
        } else if let rect = draggingRect, rect.width >= minimumSize, rect.height >= minimumSize {
            confirmedRect = rect
            confirmedWindow = nil
        } else {
            phase = .idle
            return false
        }

        phase = .confirmed
        return true
    }

    // MARK: 调整已有选区

    func beginAdjust(handle: Handle, at global: CGPoint) {
        guard let rect = confirmedRect else { return }
        activeHandle = handle
        adjustAnchorRect = rect
        adjustStartPoint = global
        phase = .adjusting
    }

    @discardableResult
    func updateAdjust(to global: CGPoint) -> Bool {
        guard
            phase == .adjusting,
            let handle = activeHandle,
            let anchor = adjustAnchorRect,
            let start = adjustStartPoint
        else { return false }

        let delta = CGPoint(x: global.x - start.x, y: global.y - start.y)
        let raw = handle.apply(delta: delta, to: anchor)
        confirmedRect = clamp(raw, moving: handle.isMove)
        // 整体平移不吸附（形状不变）；拖控制点时吸附窗口边缘。
        if handle.isMove {
            guides = []
        } else {
            let (snapped, snapGuides) = snapToWindows(raw)
            confirmedRect = clamp(snapped, moving: false)
            guides = snapGuides
        }
        return true
    }

    func endAdjust() {
        guard phase == .adjusting else { return }
        activeHandle = nil
        adjustAnchorRect = nil
        adjustStartPoint = nil

        // 尺寸被拖没了就退回重选。
        if let rect = confirmedRect, rect.width < minimumSize || rect.height < minimumSize {
            reset()
            return
        }
        // 调整过之后就不再等同于原来那个窗口了，归因交给上层重新推断。
        confirmedWindow = nil
        guides = []
        phase = .confirmed
    }

    /// 方向键微调。`resizing` 为真时拖的是右上角，否则整体平移。
    @discardableResult
    func nudge(dx: CGFloat, dy: CGFloat, resizing: Bool) -> Bool {
        guard phase == .confirmed, let rect = confirmedRect else { return false }
        let handle: Handle = resizing ? .topRight : .inside
        let next = clamp(handle.apply(delta: CGPoint(x: dx, y: dy), to: rect), moving: !resizing)
        guard next.width >= minimumSize, next.height >= minimumSize else { return false }
        confirmedRect = next
        confirmedWindow = nil
        return true
    }

    /// 窗口边缘吸附：选区边接近窗口边（±snapThreshold）时自动对齐。
    private func snapToWindows(_ rect: CGRect) -> (rect: CGRect, guides: [SelectionGuide]) {
        var vLines: [CGFloat] = []
        var hLines: [CGFloat] = []
        for window in windows {
            let f = window.frame
            vLines.append(contentsOf: [f.minX, f.maxX])
            hLines.append(contentsOf: [f.minY, f.maxY])
        }
        guard !vLines.isEmpty || !hLines.isEmpty else { return (rect, []) }

        var result = rect
        var guides: [SelectionGuide] = []

        var bestH: (offset: CGFloat, line: CGFloat)?
        for edge in [result.minX, result.maxX] {
            for vl in vLines {
                let d = vl - edge
                if abs(d) <= snapThreshold, abs(d) < (bestH.map { abs($0.offset) } ?? .infinity) {
                    bestH = (d, vl)
                }
            }
        }
        if let bestH {
            result.origin.x += bestH.offset
            guides.append(SelectionGuide(isHorizontal: false, position: bestH.line))
        }

        var bestV: (offset: CGFloat, line: CGFloat)?
        for edge in [result.minY, result.maxY] {
            for hl in hLines {
                let d = hl - edge
                if abs(d) <= snapThreshold, abs(d) < (bestV.map { abs($0.offset) } ?? .infinity) {
                    bestV = (d, hl)
                }
            }
        }
        if let bestV {
            result.origin.y += bestV.offset
            guides.append(SelectionGuide(isHorizontal: true, position: bestV.line))
        }

        return (result, guides)
    }

    private func clamp(_ rect: CGRect, moving: Bool) -> CGRect {
        if moving {
            // 整体移动时只平移，不因为撞到边缘而变形。
            var moved = rect
            moved.origin.x = min(max(bounds.minX, moved.minX), bounds.maxX - moved.width)
            moved.origin.y = min(max(bounds.minY, moved.minY), bounds.maxY - moved.height)
            return moved
        }
        return rect.intersection(bounds)
    }

    /// R 键复用上次选区：从 idle 直接恢复到指定区域（含圆角半径）。
    @discardableResult
    func restoreSelection(_ rect: CGRect, cornerRadius: CGFloat = 0) -> Bool {
        // 多边形模式也属于 idle 阶段（phase 在闭合时才变 confirmed），
        // 所以这里必须单独排除：否则 R（复用上次区域）会在画多边形的途中
        // 塞进一个矩形选区，留下「多边形 + 已确认矩形」的混合状态。
        guard phase == .idle, polygon == nil else { return false }
        let clamped = rect.intersection(bounds)
        guard clamped.width >= minimumSize, clamped.height >= minimumSize else { return false }
        confirmedRect = clamped
        confirmedWindow = nil
        guides = []
        self.cornerRadius = cornerRadius
        adjustingCorner = nil
        phase = .confirmed
        return true
    }

    func reset() {
        phase = .idle
        dragOrigin = nil
        dragCurrent = nil
        confirmedRect = nil
        confirmedWindow = nil
        hoveredWindow = nil
        activeHandle = nil
        adjustAnchorRect = nil
        adjustStartPoint = nil
        guides = []
        cornerRadius = 0
        adjustingCorner = nil
        confirmedPolygon = nil
        polygon = nil
        adjustingPolygonVertex = nil
    }

    /// 把已确认的选区裁成图。冻结架构下这是纯内存操作。
    func makeCroppedImage() -> CGImage? {
        guard let rect = confirmedRect else { return nil }
        return snapshot.crop(globalRect: rect)
    }

    // MARK: - 多边形选区

    /// 是否处于多边形模式。
    var isPolygonMode: Bool { polygon != nil }

    /// 进入多边形模式。必须在 idle 状态，且不能已在多边形模式里。
    ///
    /// 这里刻意不重置已有的 `polygon`：键盘上 `P` 在 idle 阶段就是「开始多边形」，
    /// 手快连按两下不该把已经落好的顶点清空（`P` 在 confirmed 阶段才是像素化工具，
    /// 两者靠 phase 分开，与 `R` 的「复用上次区域 / 矩形工具」同一套规则）。
    func enterPolygonMode() {
        guard phase == .idle, polygon == nil else { return }
        polygon = PolygonState()
    }

    /// 多边形模式下放置顶点（mouseUp 时调用）。
    func addPolygonPoint(_ global: CGPoint) {
        guard polygon != nil else { return }
        let clamped = CGPoint(
            x: min(max(global.x, bounds.minX), bounds.maxX),
            y: min(max(global.y, bounds.minY), bounds.maxY)
        )
        polygon?.points.append(clamped)
        polygon?.segmentStart = nil
        polygon?.previewPoint = clamped
    }

    /// mouseDown：记录预览起点 + 启动预览线段。
    func beginPolygonSegment(_ global: CGPoint) {
        guard isPolygonMode else { return }
        polygon?.segmentStart = global
        polygon?.previewPoint = global
    }

    /// mouseMoved/mouseDragged：更新预览线段终点。
    func updatePolygonPreview(_ global: CGPoint) {
        guard isPolygonMode else { return }
        let r = Self.polygonHitRadius
        if let first = polygon?.points.first, (polygon?.points.count ?? 0) >= 3 {
            let dx = global.x - first.x
            let dy = global.y - first.y
            if dx * dx + dy * dy <= r * r {
                polygon?.snapToFirst = true
                polygon?.previewPoint = first
                return
            }
        }
        polygon?.snapToFirst = false
        polygon?.previewPoint = global
    }

    /// 预览线段起点：最后一个已确认顶点。没有点时为 nil（不画虚线）。
    var polygonPreviewStart: CGPoint? {
        polygon?.previewStart
    }

    /// 闭合多边形：点数 ≥ 3 且 bbox ≥ minimumSize 才 confirm。
    @discardableResult
    func confirmPolygon() -> Bool {
        guard let points = polygon?.points, points.count >= 3 else { return false }
        let bbox = points.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }
        guard bbox.width >= minimumSize, bbox.height >= minimumSize else { return false }
        confirmedRect = bbox.intersection(bounds)
        confirmedPolygon = points
        polygon = nil
        confirmedWindow = nil
        guides = []
        cornerRadius = 0
        adjustingCorner = nil
        phase = .confirmed
        return true
    }

    /// 取消多边形选区。
    func cancelPolygon() {
        polygon = nil
        confirmedPolygon = nil
        phase = .idle
    }

    // MARK: - 多边形顶点调整

    /// 命中多边形顶点（10pt 半径）。返回顶点索引，未命中返回 nil。
    func polygonVertex(at global: CGPoint) -> Int? {
        guard showsPolygonVertices, let polygon = confirmedPolygon else { return nil }
        for (i, point) in polygon.enumerated() {
            let dx = global.x - point.x
            let dy = global.y - point.y
            if dx * dx + dy * dy <= 100 { return i }
        }
        return nil
    }

    /// 开始拖拽多边形顶点。
    func beginPolygonVertexAdjust(_ index: Int, at global: CGPoint) {
        guard polygonVertex(at: global) == index else { return }
        adjustingPolygonVertex = index
        phase = .adjusting
    }

    /// 更新多边形顶点位置，重算 bbox。
    func updatePolygonVertex(to global: CGPoint) {
        guard let index = adjustingPolygonVertex,
              var polygon = confirmedPolygon, index < polygon.count else { return }
        polygon[index] = CGPoint(
            x: min(max(global.x, bounds.minX), bounds.maxX),
            y: min(max(global.y, bounds.minY), bounds.maxY)
        )
        confirmedPolygon = polygon
        let bbox = polygon.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }
        confirmedRect = bbox.intersection(bounds)
    }

    /// 结束多边形顶点拖拽。
    func endPolygonVertexAdjust() {
        adjustingPolygonVertex = nil
        if phase == .adjusting { phase = .confirmed }
    }
}
