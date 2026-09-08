import Foundation

/// 装配层：把具体插件注册到框架层的 `BuiltinPluginCatalog`。
///
/// 框架层（Plugin/）只提供注册和查询接口，不引用任何具体插件。
/// 本文件在 App/ 层，是"知道有哪些插件"的唯一地方。
///
/// 必须在 `AppSettings.shared` 第一次被访问之前调用
/// （AppSettings init 会读 `BuiltinPluginCatalog.shared.all` 作为默认值）。
@MainActor
enum PluginAssembly {

    private static var registered = false

    static func registerBuiltins() {
        guard !registered else { return }
        registered = true

        let catalog = BuiltinPluginCatalog.shared
        catalog.register(BuiltinPluginDescriptor(
            id: "capture",
            displayName: "截图",
            version: "1.0",
            symbolName: "camera",
            summary: "区域截图、滚动截图、延时截图",
            supportsLiveToggle: false,
            make: { CapturePlugin() }
        ))
        catalog.register(BuiltinPluginDescriptor(
            id: "recording",
            displayName: "录屏",
            version: "1.0",
            symbolName: "video",
            summary: "屏幕录制、GIF 导出、步骤指南",
            supportsLiveToggle: false,
            make: { RecordingPlugin() }
        ))
        catalog.register(BuiltinPluginDescriptor(
            id: "pin",
            displayName: "钉图",
            version: "1.0",
            symbolName: "pin",
            summary: "截图钉在桌面上，支持穿透和缩放",
            supportsLiveToggle: false,
            make: { PinPlugin() }
        ))
        catalog.register(BuiltinPluginDescriptor(
            id: "shelf",
            displayName: "暂存架",
            version: "1.0",
            symbolName: "tray",
            summary: "截图后浮出小卡片，拖出即 PNG",
            supportsLiveToggle: false,
            make: { ShelfPlugin() }
        ))
        catalog.register(BuiltinPluginDescriptor(
            id: InputSearchPlugin.pluginID,
            displayName: "输入即检索",
            version: "1.0",
            symbolName: "text.cursor",
            summary: "兼容微信与苹果拼音；独立 Index 输入源为可选实验组件",
            supportsLiveToggle: true,
            make: { InputSearchPlugin.shared }
        ))
        catalog.register(BuiltinPluginDescriptor(
            id: "agent",
            displayName: "Agent",
            version: "1.0",
            symbolName: "sparkles",
            summary: "AI 对话，自动调用工具查询截图和管理配置",
            supportsLiveToggle: false,
            make: { AgentPlugin.shared }
        ))
    }
}
