// MARK: - 插件注册表（阶段 1：内容模式收口）
//
// 借鉴 Emacs 的 package + major mode 思想。一个内容类型 = 一个 ContentMode，
// 注册进来后卡片框架、双击分发、渲染器查找都从这一处取，不再散落 if 链。
//
// 阶段 1 只收口「内容模式」（= major mode）。processors / actions / controls /
// hooks 在后续阶段陆续接入同一个 registry，最终一个 Plugin 的 activate 往这里
// 注册它贡献的所有东西。
//
// 框架层不直接引用 SwiftUI/AppKit 字面量 —— 内置模式定义在 Content 层
// （BuiltinContentModes），装配层注入。

@MainActor
final class PluginRegistry {

    static let shared = PluginRegistry()

    private var modes: [ContentKind: ContentMode] = [:]

    init() {}

    /// 装配层调用：注册内置内容模式（image + markdown）。
    static func registerBuiltins() {
        shared.registerMode(BuiltinContentModes.imageMode)
        shared.registerMode(BuiltinContentModes.markdownMode)
    }

    // MARK: - 注册 / 查找

    func registerMode(_ mode: ContentMode) {
        modes[mode.kind] = mode
    }

    func unregisterMode(_ kind: ContentKind) {
        modes[kind] = nil
    }

    /// 取内容模式。未注册的类型退回 image 模式（兜底）。
    func mode(for kind: ContentKind) -> ContentMode {
        modes[kind] ?? modes[.image] ?? BuiltinContentModes.imageMode
    }

    var registeredKinds: [ContentKind] { Array(modes.keys) }
}
