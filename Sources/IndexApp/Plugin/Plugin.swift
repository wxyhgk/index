import AppKit

// MARK: - 插件协议（= Emacs package）
//
// 一个自包含的功能包。activate 时往 PluginContext 里的各注册表注册自己贡献的
// 动作/处理器/快捷键/工具条控件，deactivate 时摘掉。
//
// 核心引擎只负责"管理 shot + 展示 shot + 插件注册"，"怎么产生 shot"
// （截图/录屏/钉图/暂存架）是动作包的事。
//
// 设计原则（借鉴 Emacs package.el）：
//   · 极简：activate/deactivate 两个方法，没有依赖解析
//   · 包之间靠注册表通信，不直接引用
//   · 一个插件可以贡献 mode/processor/action/control/shortcut/settings

/// 插件激活时拿到的上下文：各注册表 + 设置 + 存储。
@MainActor
struct PluginContext {
    let settings: any StyleStore
    let shotStore: any ShotReading & ShotWriting
    let pipeline: CapturePipeline
    let actionRegistry: CaptureActionRegistry
    let toolbarRegistry: ToolbarRegistry
    let hotKeyCenter: GlobalHotKeyCenter
    let pluginManager: PluginManager
    let pluginRegistry: PluginRegistry
    /// 在图库中打开指定截图（由 UI 层注入，Plugin 层不直接引用 GalleryWindowController）。
    let openShot: (Shot) -> Void
}

/// 插件协议。一个动作包 = 一个 Plugin 实现。
@MainActor
protocol Plugin: AnyObject, Sendable {
    var id: String { get }
    var displayName: String { get }
    var version: String { get }

    /// 激活：往注册表注册自己贡献的所有东西。
    func activate(_ ctx: PluginContext)

    /// 停用：摘掉注册的东西。
    func deactivate(_ ctx: PluginContext)
}

extension Plugin {
    func deactivate(_ ctx: PluginContext) {}
}

// MARK: - 插件管理器

/// 持有所有已激活插件，按顺序 activate/deactivate。
@MainActor
final class PluginManager {

    static let shared = PluginManager()

    private var plugins: [any Plugin] = []

    var activePlugins: [any Plugin] { plugins }

    func activate(_ plugin: any Plugin, ctx: PluginContext) {
        guard !plugins.contains(where: { $0.id == plugin.id }) else { return }
        plugin.activate(ctx)
        plugins.append(plugin)
    }

    func deactivate(_ pluginID: String, ctx: PluginContext) {
        guard let idx = plugins.firstIndex(where: { $0.id == pluginID }) else { return }
        plugins[idx].deactivate(ctx)
        plugins.remove(at: idx)
    }

    func deactivateAll(ctx: PluginContext) {
        for plugin in plugins.reversed() {
            plugin.deactivate(ctx)
        }
        plugins.removeAll()
    }
}
