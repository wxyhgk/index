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
    ///
    /// 截图工具条要短：只平铺主力动作（`isPrimary`），其余聚合成一个
    /// 「更多」菜单控件；钉图窗口空间充裕，动作全量平铺、不折叠。
    func controls(for scope: ActionScope) -> [any ToolbarControl] {
        let registered = controls.filter { $0.scopes.contains(scope) }
        let descriptors = CaptureActionRegistry.shared.descriptors(in: scope)

        var actions: [any ToolbarControl]
        if scope == .capture {
            let primary = descriptors.filter(\.isPrimary)
            let secondary = descriptors.filter { !$0.isPrimary }
            actions = primary.enumerated()
                .map { ActionControl(descriptor: $1, order: $0, scope: scope) }
            if !secondary.isEmpty {
                actions.append(MoreActionsControl(
                    descriptors: secondary, order: primary.count, scope: scope
                ))
            }
        } else {
            actions = descriptors.enumerated()
                .map { ActionControl(descriptor: $1, order: $0, scope: scope) }
        }

        return (registered + actions).sorted {
            $0.group == $1.group ? $0.order < $1.order : $0.group < $1.group
        }
    }
}
