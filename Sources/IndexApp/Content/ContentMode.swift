import SwiftUI
import AppKit

// MARK: - 内容模式（= Emacs major mode）
//
// 一个内容类型的完整行为描述：顶部 bar 样式、底部 caption、
// 中间内容区渲染器、双击动作。一个 shot 的 contentKind 决定它的一切 ——
// 注册一个 ContentMode 到 PluginRegistry，不改卡片框架、不改双击分发。
//
// 录屏（isRecording）是正交维度（任何 kind 都可能是录屏附件），
// 不在 mode 里，由卡片层覆盖（见 CardAppearance.forShot）。

struct ContentMode {
    let kind: ContentKind
    /// 顶部 bar 标签。
    let label: String
    /// 顶部 bar 颜色。
    let barColor: Color
    /// 固定图标（nil 时用来源 App 图标）。
    let icon: NSImage?
    /// 底部 caption（标题 + 副标题）。
    let caption: (Shot) -> (title: String, subtitle: String)
    /// 中间内容区渲染器。
    let renderer: any ContentRenderer
    /// 双击动作。
    let doubleClick: CardDoubleClickAction
    /// 该 mode 下的快捷键（= Emacs mode-specific keymap）。
    /// key 是动作名（如 "bold"），value 是快捷键。
    /// 查找顺序：mode keymap → global keymap（见 KeymapRegistry）。
    var keymap: [String: KeyboardShortcut]
}
