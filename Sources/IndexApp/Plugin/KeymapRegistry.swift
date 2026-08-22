import AppKit

// MARK: - 快捷键分层注册表（= Emacs keymap 分层）
//
// 查找顺序：mode keymap → global keymap。
// 同一个动作名（如 "bold"）在不同 mode 下可以绑不同快捷键：
//   · Markdown mode：⌘B 加粗
//   · Code mode：⌘B 断点（后续）
//   · 全局：⌘B 未定义（或别的）
//
// 插件在 activate 时注册 mode 级快捷键，全局快捷键由 AppDelegate 注册。

@MainActor
final class KeymapRegistry: Sendable {

    static let shared = KeymapRegistry()

    /// 全局快捷键（最底层）。
    private var global: [String: KeyboardShortcut] = [:]

    /// mode 级快捷键（覆盖全局）。
    private var modeMaps: [ContentKind: [String: KeyboardShortcut]] = [:]

    // MARK: - 注册

    func registerGlobal(_ action: String, shortcut: KeyboardShortcut) {
        global[action] = shortcut
    }

    func registerMode(_ kind: ContentKind, _ action: String, shortcut: KeyboardShortcut) {
        modeMaps[kind, default: [:]][action] = shortcut
    }

    /// 从 ContentMode 批量注册（mode 声明的 keymap）。
    func registerMode(_ mode: ContentMode) {
        for (action, shortcut) in mode.keymap {
            modeMaps[mode.kind, default: [:]][action] = shortcut
        }
    }

    // MARK: - 查找

    /// 分层查找：mode keymap → global keymap。
    func shortcut(for action: String, in kind: ContentKind) -> KeyboardShortcut? {
        modeMaps[kind]?[action] ?? global[action]
    }

    // MARK: - 清理

    func clearMode(_ kind: ContentKind) {
        modeMaps[kind] = nil
    }

    func clearGlobal() {
        global = [:]
    }
}
