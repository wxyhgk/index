import AppKit
import SwiftUI

@MainActor
final class GalleryWindowController: NSWindowController, NSWindowDelegate {

    static let shared = GalleryWindowController()

    private init() {
        let hosting = NSHostingController(rootView: GalleryView())
        let window = NSWindow(contentViewController: hosting)
        window.title = "MacShot 图库"
        window.setContentSize(NSSize(width: 1080, height: 700))
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = false
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(selecting shot: Shot? = nil) {
        ShotStore.shared.reload()
        if let shot {
            GallerySelection.shared.selectedID = shot.id
        }
        // 菜单栏 App 平时是 .accessory，开窗口时切成 .regular 才有正常的窗口行为和菜单。
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
