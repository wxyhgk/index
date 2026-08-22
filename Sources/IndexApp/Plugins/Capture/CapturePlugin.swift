import AppKit

// MARK: - 截图插件
//
// 截图 + 滚动截图 + 截图后处理（OCR/浏览器地址/分类/Vision 标签/特征指纹/
// CLIP/敏感内容/Markdown 生成）。
//
// activate 时往 pipeline 注册全部截图后处理器（= Emacs minor mode，截图落库后触发）。
// 动作（CaptureAction）暂由 AppDelegate 的 registerBuiltins 统一注册，
// 后续阶段拆到各插件。

@MainActor
final class CapturePlugin: Plugin {
    let id = "capture"
    let displayName = "截图"
    let version = "1.0"

    func activate(_ ctx: PluginContext) {
        // 截图后处理器
        CapturePipeline.registerBuiltins(into: ctx.pipeline, styleStore: ctx.settings)
    }
}
