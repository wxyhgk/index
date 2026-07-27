import AppKit
import SwiftUI

/// 标注编辑器的独立窗口。每个 shot 一个窗口实例 —— 编辑不再是模态 sheet，
/// 图库照常可用，多张截图可以并排同时编辑、互相参考。
///
/// 生命周期由 `WindowRegistry.present(dockIcon: true, retain: true)` 统一持有
/// （同钉图的持有方式；编辑器是「正经窗口」，参与 Dock 图标引用计数）。
/// 查重是本控制器自己的弱引用映射：WindowRegistry 只管生命周期不做查重，
/// 同一张图重复打开时激活已有窗口而不是再开一个。
@MainActor
final class EditorWindowController: NSWindowController {

    /// shotID → 已打开的编辑器窗口。**弱引用** —— 强持有仍在 WindowRegistry
    /// （retain: true）那一份，这里只做查重，窗口析构后自动出表，
    /// 不构成第二套 living 集合。
    private static let openEditors =
        NSMapTable<NSNumber, EditorWindowController>.strongToWeakObjects()

    /// 所有编辑器窗口共用一个 frame autosave 名：用户预期是
    /// 「编辑器上次的位置和大小」，按 shot 独立记没有必要。
    private static let frameAutosaveName = "MacShotEditor"

    /// 打开（或激活）某张截图的编辑器窗口。
    static func open(_ shot: Shot) {
        if let id = shot.id,
           let existing = openEditors.object(forKey: NSNumber(value: id)) {
            NSApp.activate(ignoringOtherApps: true)
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }

        let controller = EditorWindowController(shot: shot)
        if let id = shot.id {
            openEditors.setObject(controller, forKey: NSNumber(value: id))
        }
        WindowRegistry.shared.present(controller, dockIcon: true, retain: true)
    }

    private init(shot: Shot) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "标注 — \(shot.sourceSummary)"

        // 「关闭」按钮走注入的回调关掉宿主窗口（sheet 时代的 dismiss 在这里没用）。
        // 闭包捉的是窗口不是控制器 —— 控制器要到 super.init 之后才存在。
        window.contentViewController = NSHostingController(
            rootView: EditorView(shot: shot, onClose: { [weak window] in
                window?.close()
            })
        )

        // 挂上内容后再定尺寸：NSHostingController 会把窗口缩到视图的理想尺寸。
        window.setContentSize(NSSize(width: 1000, height: 680))
        // 恢复上一次编辑器窗口的位置与大小；首次打开没有记录时居中。
        if !window.setFrameUsingName(Self.frameAutosaveName) {
            window.center()
        }
        // 同名 autosave 同时只能挂在一个窗口上：第二个编辑器挂不上（返回 false）,
        // 只恢复不追踪，并往右下错开一点，避免和已有窗口完全重叠。
        if !window.setFrameAutosaveName(Self.frameAutosaveName) {
            window.setFrameTopLeftPoint(
                NSPoint(x: window.frame.minX + 28, y: window.frame.maxY - 28)
            )
        }

        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError() }
}
