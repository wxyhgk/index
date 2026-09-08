import Foundation

/// 装配内置插件并为明确支持的插件提供当前进程即时启停。
@MainActor
final class BuiltinPluginHost {
    static let shared = BuiltinPluginHost()

    private var context: PluginContext?
    private var pluginsByID: [String: any Plugin] = [:]

    private init() {}

    func configure(context: PluginContext, enabledPluginIDs: [String]) {
        shutdown()
        self.context = context
        let catalog = BuiltinPluginCatalog.shared
        pluginsByID = Dictionary(
            uniqueKeysWithValues: catalog.all.map { descriptor in
                (descriptor.id, descriptor.make())
            }
        )

        for descriptor in catalog.all
        where Self.isEnabled(descriptor.id, in: enabledPluginIDs) {
            guard let plugin = pluginsByID[descriptor.id] else { continue }
            context.pluginManager.activate(plugin, ctx: context)
        }
    }

    /// 设置页修改后，只即时同步已经声明支持完整 deactivate 的插件。
    func applyLiveSettings(enabledPluginIDs: [String]) {
        guard let context else { return }
        for descriptor in BuiltinPluginCatalog.shared.all where descriptor.supportsLiveToggle {
            let shouldBeActive = Self.isEnabled(descriptor.id, in: enabledPluginIDs)
            if shouldBeActive, !context.pluginManager.isActive(descriptor.id),
               let plugin = pluginsByID[descriptor.id] {
                context.pluginManager.activate(plugin, ctx: context)
            } else if !shouldBeActive, context.pluginManager.isActive(descriptor.id) {
                context.pluginManager.deactivate(descriptor.id, ctx: context)
            }
        }
    }

    func isActive(_ pluginID: String) -> Bool {
        context?.pluginManager.isActive(pluginID) == true
    }

    func shutdown() {
        guard let context else { return }
        context.pluginManager.deactivateAll(ctx: context)
        self.context = nil
        pluginsByID = [:]
    }

    static func isEnabled(_ pluginID: String, in enabledPluginIDs: [String]) -> Bool {
        enabledPluginIDs.contains(pluginID)
    }
}
