import AppKit

// MARK: - 录屏插件
//
// 录屏 + 区域选择 + 音频 + GIF 导出 + 步骤指南。
//
// activate 时注册录屏相关动作。停用后录屏快捷键和工具条按钮消失。

@MainActor
final class RecordingPlugin: Plugin {
    let id = "recording"
    let displayName = "录屏"
    let version = "1.0"

    func activate(_ ctx: PluginContext) {
        // 录屏动作（截图工具条上的"录屏"入口）
        ctx.actionRegistry.register(RecordAction())
    }
}
