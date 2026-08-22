import AppKit
import CoreGraphics

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
    private let minimumSize: CGFloat = 2

    private(set) var phase: Phase = .idle
    private(set) var hoveredWindow: WindowInfo?
    private(set) var confirmedRect: CGRect?
    private(set) var confirmedWindow: WindowInfo?
    /// 别的屏已经在操作了，这块屏只保留压暗。
    private(set) var isInactive = false

    private var dragOrigin: CGPoint?
    private var dragCurrent: CGPoint?

    private var activeHandle: Handle?
    /// 覆盖层判断是否为整体平移（`inside`）时用 —— `activeHandle` 私有，暴露只读。
    var adjustingHandle: Handle? { activeHandle }
    private var adjustAnchorRect: CGRect?
    private var adjustStartPoint: CGPoint?

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
        if let draggingRect { return draggingRect }
        guard !isInactive, phase == .idle else { return nil }
        return hoveredWindow?.frame.intersection(bounds)
    }

    /// 高亮的是「悬停到的窗口」而非用户画出来的选区 —— 用来区分蓝框和白框。
    var isWindowHint: Bool {
        phase == .idle && confirmedRect == nil
    }

    /// 选区已定，可以显示控制点。
    var showsHandles: Bool {
        (phase == .confirmed || phase == .adjusting) && confirmedRect != nil
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
        dragOrigin = global
        dragCurrent = global
        phase = .dragging
    }

    @discardableResult
    func updateDrag(to global: CGPoint) -> Bool {
        guard phase == .dragging else { return false }
        dragCurrent = global
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
        confirmedRect = clamp(handle.apply(delta: delta, to: anchor), moving: handle.isMove)
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
    }

    /// 把已确认的选区裁成图。冻结架构下这是纯内存操作。
    func makeCroppedImage() -> CGImage? {
        guard let rect = confirmedRect else { return nil }
        return snapshot.crop(globalRect: rect)
    }
}
