import SwiftUI
import AppKit
import Carbon.HIToolbox

// MARK: - 插件注册表（阶段 1：内容模式收口）
//
// 借鉴 Emacs 的 package + major mode 思想。一个内容类型 = 一个 ContentMode，
// 注册进来后卡片框架、双击分发、渲染器查找都从这一处取，不再散落 if 链。
//
// 阶段 1 只收口「内容模式」（= major mode）。processors / actions / controls /
// hooks 在后续阶段陆续接入同一个 registry，最终一个 Plugin 的 activate 往这里
// 注册它贡献的所有东西。

@MainActor
final class PluginRegistry {

    static let shared = PluginRegistry()

    private var modes: [ContentKind: ContentMode] = [:]

    init() {
        registerMode(Self.imageMode)
        registerMode(Self.markdownMode)
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
        modes[kind] ?? modes[.image] ?? Self.imageMode
    }

    var registeredKinds: [ContentKind] { Array(modes.keys) }

    // MARK: - 内置模式

    /// 图片模式（兜底）：蓝条 / App 图标 / 时间 caption。
    static let imageMode = ContentMode(
        kind: .image,
        label: "截图",
        barColor: DS.clipboardImageBar,
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
