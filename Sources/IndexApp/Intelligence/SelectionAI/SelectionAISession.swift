import CoreGraphics

enum SelectionAISessionPhase: Equatable, Sendable {
    /// 工具未启用，画布事件完全交回原宿主。
    case inactive
    /// 工具已启用，等待用户开始框选。
    case armed
    case dragging
    /// 已得到可提交给任务菜单的像素区域。
    case selected
}

struct SelectionAISessionSnapshot: Equatable, Sendable {
    let phase: SelectionAISessionPhase
    let selectionRect: CGRect?

    var isActive: Bool { phase != .inactive }
}

/// 智能选区的宿主无关状态机。
///
/// 它只接受图像像素坐标，不认识 AppKit/SwiftUI 事件，也不执行 Provider。Toolbar、
/// 截图覆盖层、钉图和图库编辑器可以共享同一实例，宿主每次调用后自行触发重绘。
@MainActor
final class SelectionAISession {
    let minimumSide: CGFloat

    private(set) var phase: SelectionAISessionPhase = .inactive
    private(set) var selectionRect: CGRect?
    private var anchor: CGPoint?

    init(minimumSide: CGFloat = 8) {
        self.minimumSide = max(1, minimumSide)
    }

    var snapshot: SelectionAISessionSnapshot {
        SelectionAISessionSnapshot(phase: phase, selectionRect: selectionRect)
    }

    func activate() {
        phase = .armed
        selectionRect = nil
        anchor = nil
    }

    func deactivate() {
        phase = .inactive
        selectionRect = nil
        anchor = nil
    }

    func toggle() {
        phase == .inactive ? activate() : deactivate()
    }

    /// 只有落点真的在图像内才接管手势；在画布外按下仍由原宿主处理。
    @discardableResult
    func begin(at point: CGPoint, within bounds: CGRect) -> Bool {
        guard phase == .armed || phase == .selected,
              SelectionAIGeometry.isUsableBounds(bounds),
              bounds.standardized.contains(point)
        else { return false }

        anchor = point
        selectionRect = CGRect(origin: point, size: .zero)
        phase = .dragging
        return true
    }

    @discardableResult
    func update(to point: CGPoint, within bounds: CGRect) -> Bool {
        guard phase == .dragging, let anchor,
              let rect = SelectionAIGeometry.previewRect(
                  from: anchor,
                  to: point,
                  within: bounds
              )
        else { return false }

        let changed = selectionRect != rect
        selectionRect = rect
        return changed
    }

    /// 返回最终图像像素矩形。轻点或过小选区回到 armed，继续等待下一次框选。
    @discardableResult
    func end(at point: CGPoint, within bounds: CGRect) -> CGRect? {
        guard phase == .dragging, let anchor else { return nil }
        defer { self.anchor = nil }

        guard let rect = SelectionAIGeometry.finalizedRect(
            from: anchor,
            to: point,
            within: bounds,
            minimumSide: minimumSide
        ) else {
            phase = .armed
            selectionRect = nil
            return nil
        }

        phase = .selected
        selectionRect = rect
        return rect
    }

    /// Esc/右键的逐级退出：拖拽或已有选区先退回待框选，再按一次才退出工具。
    /// inactive 时返回 false，表示本层没有消费退出事件。
    @discardableResult
    func stepBack() -> Bool {
        switch phase {
        case .inactive:
            return false
        case .armed:
            deactivate()
        case .dragging, .selected:
            phase = .armed
            selectionRect = nil
            anchor = nil
        }
        return true
    }
}
