import Foundation

/// 内置插件的描述符。
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

/// 插件注册表。框架层只提供注册和查询接口，不引用任何具体插件。
/// 具体插件的注册由装配层（`PluginAssembly`）在启动时完成。
@MainActor
final class BuiltinPluginCatalog {
    static let shared = BuiltinPluginCatalog()

    private var descriptors: [BuiltinPluginDescriptor] = []

    private init() {}

    func register(_ descriptor: BuiltinPluginDescriptor) {
        descriptors.append(descriptor)
    }

    var all: [BuiltinPluginDescriptor] { descriptors }

    func descriptor(id: String) -> BuiltinPluginDescriptor? {
        descriptors.first { $0.id == id }
    }
}
