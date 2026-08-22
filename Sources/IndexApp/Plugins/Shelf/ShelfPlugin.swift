import AppKit

// MARK: - 暂存架插件
//
// 截图后的暂存架卡片（拖拽/导出/删除）。
//
// activate 时不需要注册动作（暂存架由截图流程自动触发），
// 保留插件壳是为了后续支持独立启停。

@MainActor
final class ShelfPlugin: Plugin {
    let id = "shelf"
    let displayName = "暂存架"
    let version = "1.0"

    func activate(_ ctx: PluginContext) {
        // 暂存架由截图流程自动触发，无需注册动作。
        // 保留插件壳：后续可加独立启停、自定义暂存架样式等。
    }
}
