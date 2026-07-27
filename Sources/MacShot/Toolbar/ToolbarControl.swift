import AppKit

/// 控件分组。同组的挨在一起，组之间自动插分隔线；
/// 空间不够时在 `.actions` 之前折行。
enum ToolbarGroup: Int, Comparable {
    case tools = 0
    case style = 1
    case history = 2
    case actions = 3

    static func < (lhs: ToolbarGroup, rhs: ToolbarGroup) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// 控件绘制和响应时能看到的东西。
@MainActor
struct ToolbarContext {
    let annotation: AnnotationState
    let scope: ActionScope
    /// 触发一个出口动作（见 `CaptureAction`）。
    let perform: (String) -> Void
    /// 选字（Live Text）模式是否激活。
    let isLiveTextActive: () -> Bool
    /// 开关选字模式。设备不支持（Intel / 低版本）或宿主没接入时为 nil，
    /// 「选字」控件据此整个不出现。
    let toggleLiveText: (() -> Void)?

    init(
        annotation: AnnotationState,
        scope: ActionScope,
        perform: @escaping (String) -> Void,
        isLiveTextActive: @escaping () -> Bool = { false },
        toggleLiveText: (() -> Void)? = nil
    ) {
        self.annotation = annotation
        self.scope = scope
        self.perform = perform
        self.isLiveTextActive = isLiveTextActive
        self.toggleLiveText = toggleLiveText
    }
}

/// 绘制时的高亮状态。底板和高亮由渲染器统一画，控件只画自己的内容。
struct ToolbarRenderState {
    let isSelected: Bool
    let isHovered: Bool
}

/// 工具条上的一个可点元素。
///
/// 新增控件（字号、透明度、序号计数器、形状填充开关……）=
/// 新增一个实现 + 在 `BuiltinControls.registerAll` 里加一行。
/// **不需要**改布局、渲染、覆盖层或钉图窗口 —— 此前这四处各有一个 switch，
/// 其中覆盖层和钉图窗口那两个还是重复的。
@MainActor
protocol ToolbarControl {
    var id: String { get }
    var scopes: Set<ActionScope> { get }
    var group: ToolbarGroup { get }
    /// 组内排序。
    var order: Int { get }

    /// 上下文相关的显隐。颜色只在拿着画笔时出现，撤销只在有东西可撤时出现。
    func isVisible(_ context: ToolbarContext) -> Bool
    func isSelected(_ context: ToolbarContext) -> Bool
    func width(_ context: ToolbarContext) -> CGFloat
    func draw(in frame: CGRect, context: ToolbarContext, state: ToolbarRenderState)
    func activate(_ context: ToolbarContext)
}

extension ToolbarControl {
    func isVisible(_ context: ToolbarContext) -> Bool { true }
    func isSelected(_ context: ToolbarContext) -> Bool { false }
    func width(_ context: ToolbarContext) -> CGFloat { ToolbarStyle.iconButtonWidth }
}

/// 布局算好的一个位置。绘制和命中测试用同一份结果。
@MainActor
struct ToolbarSlot {
    /// 视图局部坐标。
    let frame: CGRect
    /// nil 表示这是一条分隔线。
    let control: (any ToolbarControl)?

    var id: String { control?.id ?? "separator" }
}
