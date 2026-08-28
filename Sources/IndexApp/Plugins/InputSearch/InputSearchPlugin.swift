import Foundation

/// 与现有中文输入法共存的默认检索插件。
///
/// 它不接管组字和候选；平台副作用继续由 FocusedTextSearchController 收口。
/// 独立 InputMethodKit bundle 是可选高级组件，不属于本插件进程。
@MainActor
final class InputSearchPlugin: Plugin {
    static let shared = InputSearchPlugin()
    static let pluginID = "input-search"

    let id = pluginID
    let displayName = "输入即检索"
    let version = "1.0"

    private let controller = FocusedTextSearchController()

    private init() {}

    var isSearchEnabled: Bool { controller.isEnabled }

    func activate(_ ctx: PluginContext) {
        controller.restoreIfEnabled()
    }

    func deactivate(_ ctx: PluginContext) {
        controller.stop()
    }

    func setSearchEnabled(_ enabled: Bool) {
        controller.setEnabled(enabled)
    }
}
