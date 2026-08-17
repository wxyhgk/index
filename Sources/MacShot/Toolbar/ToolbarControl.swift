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

/// 某张钉图带有分子来源时才注入。Toolbar 不读取数据库、不写文件，只负责把
/// 用户选择的来源操作回调给宿主。
struct MoleculeSourceActions {
    let copyXYZ: () -> Void
    let openInDefaultApp: () -> Void
    let reopen3D: () -> Void
}

/// 控件绘制和响应时能看到的东西。
@MainActor
struct ToolbarContext {
    let annotation: AnnotationState
    let scope: ActionScope
    /// 触发一个出口动作（见 `CaptureAction`）。
    let perform: (String) -> Void
    /// Live Text、AI 选区等不产生图层的临时画布能力。
    let capabilities: ToolbarHostCapabilities
    /// 某个出口动作是否正在当前宿主中执行。
    let isActionExecuting: (String) -> Bool
    /// 普通图片为 nil；由 XYZ 定格得到的钉图提供三个来源动作。
    let moleculeSourceActions: MoleculeSourceActions?

    init(
        annotation: AnnotationState,
        scope: ActionScope,
        perform: @escaping (String) -> Void,
        capabilities: ToolbarHostCapabilities = .none,
        isActionExecuting: @escaping (String) -> Bool = { _ in false },
        moleculeSourceActions: MoleculeSourceActions? = nil
    ) {
        self.annotation = annotation
        self.scope = scope
        self.perform = perform
        self.capabilities = capabilities
        self.isActionExecuting = isActionExecuting
        self.moleculeSourceActions = moleculeSourceActions
    }
}

/// 绘制时的高亮状态。底板和高亮由渲染器统一画，控件只画自己的内容。
struct ToolbarRenderState {
    let isSelected: Bool
    let isHovered: Bool
    let isFocused: Bool
    let isPressed: Bool
    let isEnabled: Bool
    let isBusy: Bool
}

/// 自绘工具条的键盘焦点导航。输入只有当前可用控件 ID，因此 Overlay 与钉图
/// 可以共享完全一致的 Tab / Shift-Tab / 左右键行为。
struct ToolbarFocusNavigator {
    static func next(in ids: [String], current: String?, offset: Int) -> String? {
        guard !ids.isEmpty, offset != 0 else { return current }
        guard let current, let index = ids.firstIndex(of: current) else {
            return offset > 0 ? ids.first : ids.last
        }
        let next = (index + offset % ids.count + ids.count) % ids.count
        return ids[next]
    }
}

/// 把触控板的连续小数滚动累积成离散的工具参数步进。
/// 普通鼠标滚轮没有 precise delta，一格立即产生一步。
struct ToolbarScrollAccumulator {
    static let preciseThreshold: CGFloat = 6

    private(set) var value: CGFloat = 0

    mutating func reset() { value = 0 }

    mutating func step(delta: CGFloat, isPrecise: Bool) -> Int? {
        guard delta != 0 else { return nil }
        guard isPrecise else {
            value = 0
            return delta > 0 ? 1 : -1
        }

        // 反向滚动先抵消上一方向的残量，避免轻微回弹立即跨档。
        value += delta
        guard abs(value) >= Self.preciseThreshold else { return nil }
        let step = value > 0 ? 1 : -1
        value -= CGFloat(step) * Self.preciseThreshold
        return step
    }
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

    /// 上下文相关的显隐与可用态。颜色只在拿着画笔时出现；历史按钮固定
    /// 占位，无历史时通过 `isEnabled` 变成禁用态，避免后方动作横向跳动。
    func isVisible(_ context: ToolbarContext) -> Bool
    func isEnabled(_ context: ToolbarContext) -> Bool
    func isBusy(_ context: ToolbarContext) -> Bool
    func isSelected(_ context: ToolbarContext) -> Bool
    /// Tooltip、键盘焦点提示和无障碍描述共用的用户可读名称。
    func accessibilityLabel(_ context: ToolbarContext) -> String
    func width(_ context: ToolbarContext) -> CGFloat
    func draw(in frame: CGRect, context: ToolbarContext, state: ToolbarRenderState)
    func activate(_ context: ToolbarContext)
}

extension ToolbarControl {
    func isVisible(_ context: ToolbarContext) -> Bool { true }
    func isEnabled(_ context: ToolbarContext) -> Bool { true }
    func isBusy(_ context: ToolbarContext) -> Bool { false }
    func isSelected(_ context: ToolbarContext) -> Bool { false }
    func accessibilityLabel(_ context: ToolbarContext) -> String { id }
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

    /// 命中区：绘制 frame 外扩 `hitPadding`（Fitts 定律 —— 热区大于视觉区，
    /// 小按钮更好点中）。绘制仍用 `frame`，只有命中测试用这个。
    var hitFrame: CGRect {
        frame.insetBy(dx: -ToolbarStyle.hitPadding, dy: -ToolbarStyle.hitPadding)
    }
}
