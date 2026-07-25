import AppKit
import SwiftUI

/// 独立的标注编辑器窗口（截图工具条上点「标注」走这里）。
/// 图库里的编辑仍然用 sheet，两者共用同一个 `EditorView`。
@MainActor
final class EditorWindowController: NSWindowController, NSWindowDelegate {

    private static var living: Set<EditorWindowController> = []

    static func open(shot: Shot) {
        let controller = EditorWindowController(shot: shot)
        living.insert(controller)

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    private init(shot: Shot) {
        // 先建窗口，再把关闭回调注入 SwiftUI —— 编辑器里的「关闭」按钮要能关掉这个 NSWindow。
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "标注 — \(shot.sourceSummary)"
        window.center()
        super.init(window: window)

        window.delegate = self
        window.contentViewController = NSHostingController(
            rootView: EditorView(shot: shot, onClose: { [weak self] in
                self?.close()
            })
        )
    }

    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) {
        Self.living.remove(self)
        // 没有别的可见窗口了就退回菜单栏模式。
        let hasVisibleWindow = NSApp.windows.contains {
            $0.isVisible && $0 !== window && !($0 is NSPanel)
        }
        if !hasVisibleWindow {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
