import AppKit

// MARK: - 钉图插件
//
// 钉图 + 标注 + 分子式。
//
// activate 时注册钉图动作。停用后钉图快捷键和工具条按钮消失。

@MainActor
final class PinPlugin: Plugin {
    let id = "pin"
    let displayName = "钉图"
    let version = "1.0"

    func activate(_ ctx: PluginContext) {
        // 钉图动作（截图工具条上的"钉图"入口）
        ctx.actionRegistry.register(
            PinAction(capture: ctx.settings, annotationStyle: ctx.settings)
        )
    }
}
