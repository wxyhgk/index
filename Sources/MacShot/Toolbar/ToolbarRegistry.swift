import AppKit

/// 工具条控件注册表。
///
/// 布局和渲染只问它「这个场景有哪些控件」，不认识任何具体控件类型。
/// 出口动作不在这里 —— 它们由 `CaptureActionRegistry` 自动展开成控件，
/// 所以新增一个动作仍然只要写一个 `CaptureAction`。
@MainActor
final class ToolbarRegistry {

    static let shared = ToolbarRegistry()

    private var controls: [any ToolbarControl] = []

    init() {}

    func register(_ control: any ToolbarControl) {
        controls.removeAll { $0.id == control.id }
        controls.append(control)
    }

    /// 某个场景下按分组和组内顺序排好的全部控件（含由动作展开来的）。
    func controls(for scope: ActionScope) -> [any ToolbarControl] {
        let registered = controls.filter { $0.scopes.contains(scope) }
        let actions = CaptureActionRegistry.shared.descriptors(in: scope)
            .enumerated()
            .map { ActionControl(descriptor: $1, order: $0, scope: scope) }

        return (registered + actions).sorted {
            $0.group == $1.group ? $0.order < $1.order : $0.group < $1.group
        }
    }
}
