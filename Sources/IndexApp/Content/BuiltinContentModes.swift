import SwiftUI
import AppKit
import Carbon.HIToolbox

// MARK: - 内置内容模式
//
// 从 PluginRegistry 移来：Plugin 框架层不应直接引用 SwiftUI/AppKit 字面量。
// 装配层（AppDelegate）调 PluginRegistry.registerBuiltins() 时引用这里的定义。

enum BuiltinContentModes {

    /// 图片模式（兜底）：蓝条 / App 图标 / 时间 caption。
    static let imageMode = ContentMode(
        kind: .image,
        label: "截图",
        barColor: .blue,
        icon: nil,
        caption: { shot in
            (shot.customTitle ?? shot.primaryDisplayName,
             shot.capturedAt.formatted(.dateTime.month().day().hour().minute()))
        },
        renderer: ImageContentRenderer(),
        doubleClick: .none,
        keymap: [:]
    )

    /// Markdown 便签模式：黑条 / M 图标 / "Markdown" caption / 双击开编辑器。
    static let markdownMode = ContentMode(
        kind: .markdown,
        label: "便签",
        barColor: .primary,
        icon: CardAppearance.markdownIcon,
        caption: { shot in
            (shot.customTitle ?? shot.windowTitle ?? "便签", "Markdown")
        },
        renderer: MarkdownContentRenderer(),
        doubleClick: .openMarkdownEditor,
        keymap: [
            "bold": KeyboardShortcut(keyCode: 66, modifiers: UInt32(cmdKey)),
            "italic": KeyboardShortcut(keyCode: 75, modifiers: UInt32(cmdKey)),
        ]
    )
}
