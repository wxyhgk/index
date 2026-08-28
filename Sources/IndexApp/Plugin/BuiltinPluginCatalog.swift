import Foundation

/// 内置插件的唯一目录。启动装配与设置页都从这里读取，避免两份 ID/名称列表漂移。
@MainActor
struct BuiltinPluginDescriptor: Identifiable {
    let id: String
    let displayName: String
    let version: String
    let symbolName: String
    let summary: String
    /// 旧插件尚未完整实现 unregister；只有声明支持的插件可在当前进程即时启停。
    let supportsLiveToggle: Bool
    let make: @MainActor () -> any Plugin
}

@MainActor
enum BuiltinPluginCatalog {
    static var descriptors: [BuiltinPluginDescriptor] {
        allDescriptors.filter { descriptor in
            descriptor.id != InputSearchPlugin.pluginID
                || IndexDistribution.supportsGlobalAccessibilityFeatures
        }
    }

    private static let allDescriptors: [BuiltinPluginDescriptor] = [
        BuiltinPluginDescriptor(
            id: "capture",
            displayName: "截图",
            version: "1.0",
            symbolName: "camera",
            summary: "区域截图、滚动截图、延时截图",
            supportsLiveToggle: false,
            make: { CapturePlugin() }
        ),
        BuiltinPluginDescriptor(
            id: "recording",
            displayName: "录屏",
            version: "1.0",
            symbolName: "video",
            summary: "屏幕录制、GIF 导出、步骤指南",
            supportsLiveToggle: false,
            make: { RecordingPlugin() }
        ),
        BuiltinPluginDescriptor(
            id: "pin",
            displayName: "钉图",
            version: "1.0",
            symbolName: "pin",
            summary: "截图钉在桌面上，支持穿透和缩放",
            supportsLiveToggle: false,
            make: { PinPlugin() }
        ),
        BuiltinPluginDescriptor(
            id: "shelf",
            displayName: "暂存架",
            version: "1.0",
            symbolName: "tray",
            summary: "截图后浮出小卡片，拖出即 PNG",
            supportsLiveToggle: false,
            make: { ShelfPlugin() }
        ),
        BuiltinPluginDescriptor(
            id: "input-search",
            displayName: "输入即检索",
            version: "1.0",
            symbolName: "text.cursor",
            summary: "兼容微信与苹果拼音；独立 Index 输入源为可选实验组件",
            supportsLiveToggle: true,
            make: { InputSearchPlugin.shared }
        ),
        BuiltinPluginDescriptor(
            id: "agent",
            displayName: "Agent",
            version: "1.0",
            symbolName: "sparkles",
            summary: "AI 对话，自动调用工具查询截图和管理配置",
            supportsLiveToggle: false,
            make: { AgentPlugin.shared }
        ),
    ]

    static func descriptor(id: String) -> BuiltinPluginDescriptor? {
        descriptors.first { $0.id == id }
    }
}
