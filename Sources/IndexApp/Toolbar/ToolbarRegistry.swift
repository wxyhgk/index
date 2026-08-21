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
    /// 工具条只平铺主力动作（`isPrimary`），其余一律聚合成一个「更多」菜单控件。
    ///
    /// 这里**不按 scope 分叉**。曾经只有截图场景折叠，钉图全量平铺，理由是
    /// 「钉图窗口空间充裕」—— 那个理由随工具条独立成窗而失效：工具条现在按内容
    /// 开自然尺寸，跟钉图窗口多大再无关系，全量平铺会让一张 100pt 的小钉图下面
    /// 挂一条几百点宽的横条。折叠统一之后，注册表也不再需要认识具体场景。
    func controls(for scope: ActionScope) -> [any ToolbarControl] {
        let registered = controls.filter { $0.scopes.contains(scope) }
        let descriptors = CaptureActionRegistry.shared.descriptors(in: scope)

        let primary = descriptors.filter(\.isPrimary)
        let secondary = descriptors.filter { !$0.isPrimary }
        var actions: [any ToolbarControl] = primary.enumerated()
            .map { ActionControl(descriptor: $1, order: $0, scope: scope) }
        if !secondary.isEmpty {
            actions.append(MoreActionsControl(
                descriptors: secondary, order: primary.count, scope: scope
            ))
        }

        return (registered + actions).sorted {
            $0.group == $1.group ? $0.order < $1.order : $0.group < $1.group
        }
    }
}
