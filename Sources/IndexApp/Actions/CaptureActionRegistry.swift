import AppKit

/// 动作注册表。
///
/// 工具条问它「这个场景有哪些动作」，协调器问它「这个 id 对应哪个动作」。
/// 两边都不认识具体的动作类型，所以增删动作不会波及它们。
@MainActor
final class CaptureActionRegistry {

    static let shared = CaptureActionRegistry()

    private var actions: [String: CaptureAction] = [:]
    /// 注册顺序即工具条上的显示顺序。
    private var order: [String] = []

    init() {}

    func register(_ action: CaptureAction) {
        if actions[action.id] == nil { order.append(action.id) }
        actions[action.id] = action
    }

    func action(id: String) -> CaptureAction? {
        actions[id]
    }

    func actions(in scope: ActionScope) -> [CaptureAction] {
        order.compactMap { actions[$0] }.filter { $0.scopes.contains(scope) }
    }

    func descriptors(in scope: ActionScope) -> [ToolbarActionDescriptor] {
        actions(in: scope).map {
            ToolbarActionDescriptor(
                id: $0.id,
                title: $0.title,
                symbolName: $0.symbolName,
                isPrimary: $0.isPrimaryAction
            )
        }
    }
}

/// 内置动作的 id。快捷键和设置里按 id 引用，避免散落字符串字面量。
enum ActionID {
    static let pin = "pin"
    static let copy = "copy"
    static let save = "save"
    static let upload = "upload"
    static let close = "close"
    static let bugReport = "bug-report"
    static let copyText = "copy-text"
    /// 只完成，不做别的。没有按钮，只由回车触发。
    static let finish = "finish"
    /// 截图工具条上常驻：点一下直接进录屏 / 长截图，不再经状态栏菜单
    static let record = "record"
    static let scrollCapture = "scroll-capture"
}
