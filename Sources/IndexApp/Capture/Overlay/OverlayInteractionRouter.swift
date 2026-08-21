import AppKit
import VisionKit

/// 光标决定：设置光标，或交还系统层（选字层的 I-beam 由它自己管）。
enum OverlayCursorDecision {
    case set(NSCursor)
    case leaveAlone
}

/// gesture target 能看到的覆盖层窄门面。
///
/// target 依赖这个协议而不是具体的 `OverlayView`，路由逻辑因此可以用
/// 假宿主单测：给定坐标与状态，断言哪个 target 消费、状态怎么变。
@MainActor
protocol OverlayGestureHost: AnyObject {
    var model: SelectionModel { get }
    var annotation: AnnotationState { get }
    var geometry: OverlayGeometry { get }
    var mode: SelectionMode { get }
    var finishOnConfirm: Bool { get }
    var allowsFullWindowCapture: Bool { get }
    var slots: [ToolbarSlot] { get }
    var toolbarContext: ToolbarContext { get }
    var interactionState: OverlayInteractionState { get }
    var selectionAITaskSlots: [OverlaySelectionAITaskSlot] { get }
    var selectionAIResultLayout: OverlaySelectionAIResultLayout? { get }
    var selectionAIHostIsActive: Bool { get }
    var liveTextOverlay: ImageAnalysisOverlayView? { get }

    func redraw()
    func redrawIfNeeded(_ changed: Bool)
    func emit(_ actionID: String)
    func emitFullWindow(_ window: WindowInfo)
    /// 手势进入活跃阶段（视图需要让窗口/协调器知道）。
    /// 不叫 `onBecameActive`：视图已有同名的回调属性。
    func becameActive()
    func updateCursor(_ local: CGPoint)
    func beginSelectionAI(atViewLocal: CGPoint) -> Bool
    func updateSelectionAI(atViewLocal: CGPoint) -> Bool
    @discardableResult
    func endSelectionAI(atViewLocal: CGPoint) -> CGRect?
    func performSelectionAITask(_ kind: SelectionAITaskKind)
    func performSelectionAIResultAction(_ action: OverlaySelectionAIResultAction)
    func enterConfirmedState()
    func syncLiveTextOverlay()
    func syncLiveTextOverlayFrame()
    func prepareLiveTextAnalysis()
    func frozenPixels(_ rect: CGRect) -> CGImage?
    /// 点是否落在系统选字层的可交互文字上（鼠标模式）。
    func hasLiveTextInteractiveItem(atViewLocal local: CGPoint) -> Bool
}

/// 覆盖层里的一个交互子系统（AI 结果面板、工具条、标注、选区……）。
///
/// 路由器按优先级查询：
/// - `mouseDown`：第一个返回 true 的 target 消费这次按下，成为**会话属主**；
///   后续的 `mouseDragged` / `mouseUp` 只投递给它。
/// - `hover` / `cursor`：每帧查询，各 target 只管自己的悬停状态与光标意见。
///
/// 新增交互子系统 = 实现这个协议 + 在 `defaultTargets()` 注册一行，
/// 视图的鼠标方法零改动。
@MainActor
protocol OverlayGestureTarget {
    /// 按下。true = 消费（本 target 成为会话属主）。
    func mouseDown(local: CGPoint, event: NSEvent, host: OverlayGestureHost) -> Bool
    /// 拖动更新。只调用会话属主。
    func mouseDragged(local: CGPoint, event: NSEvent, host: OverlayGestureHost)
    /// 释放。只调用会话属主。
    func mouseUp(local: CGPoint, event: NSEvent, host: OverlayGestureHost)
    /// 悬停。各 target 更新/清掉自己的悬停状态。
    func hover(local: CGPoint, host: OverlayGestureHost)
    /// 光标。nil = 没意见；第一个非 nil 生效。
    func cursor(local: CGPoint, host: OverlayGestureHost) -> OverlayCursorDecision?
}

/// 覆盖层事件路由器：取代视图里五条硬编码的优先级 if/else 链。
///
/// 优先级链现在是数据结构（有序 target 数组）：谁先于谁可见、可断言；
/// 最后一个 target（选区）的 `mouseDown` 恒为 true，天然是兜底。
@MainActor
final class OverlayInteractionRouter {

    private let targets: [any OverlayGestureTarget]
    /// 消费了 mouseDown 的 target；dragged/up 只投递给它。
    private var session: (any OverlayGestureTarget)?

    init(targets: [any OverlayGestureTarget]) {
        self.targets = targets
    }

    /// 默认优先级：AI 结果面板 → AI 任务板 → 工具条 → AI 选区手势 →
    /// ⌥ 整窗捕获 → plain 双击确认 → 标注 → 选区（兜底，恒消费）。
    static func defaultTargets() -> [any OverlayGestureTarget] {
        [
            OverlayAIResultPanelTarget(),
            OverlayAITaskPaletteTarget(),
            OverlayToolbarTarget(),
            OverlayAIGestureTarget(),
            OverlayFullWindowTarget(),
            OverlayPlainConfirmTarget(),
            OverlayAnnotationTarget(),
            OverlaySelectionTarget()
        ]
    }

    func mouseDown(local: CGPoint, event: NSEvent, host: OverlayGestureHost) {
        for target in targets where target.mouseDown(local: local, event: event, host: host) {
            session = target
            return
        }
    }

    func mouseDragged(local: CGPoint, event: NSEvent, host: OverlayGestureHost) {
        // 放大镜采样是每帧服务，与具体手势无关。
        host.updateCursor(local)
        session?.mouseDragged(local: local, event: event, host: host)
    }

    func mouseUp(local: CGPoint, event: NSEvent, host: OverlayGestureHost) {
        defer { session = nil }
        session?.mouseUp(local: local, event: event, host: host)
    }

    func mouseMoved(local: CGPoint, event: NSEvent, host: OverlayGestureHost) {
        switch host.model.phase {
        case .confirmed:
            // 各 target 只管自己的悬停：没命中的会清掉自己，
            // 天然实现「命中上层时下层悬停被清」的旧行为。
            for target in targets {
                target.hover(local: local, host: host)
            }
            applyCursor(local: local, host: host)
        case .idle:
            NSCursor.crosshair.set()
            host.model.hover(at: NSEvent.mouseLocation)
            host.updateCursor(local)
            host.redraw()
        case .dragging, .adjusting:
            break
        }
    }

    private func applyCursor(local: CGPoint, host: OverlayGestureHost) {
        for target in targets {
            guard let decision = target.cursor(local: local, host: host) else { continue }
            switch decision {
            case .set(let cursor): cursor.set()
            case .leaveAlone: break
            }
            return
        }
    }
}