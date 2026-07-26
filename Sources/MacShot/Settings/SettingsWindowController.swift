import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController {

    static let shared = SettingsWindowController()

    private init() {
        let hosting = NSHostingController(rootView: SettingsView())
        let window = NSWindow(contentViewController: hosting)
        window.title = "MacShot 设置"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 500, height: 460))
        window.center()
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        WindowRegistry.shared.present(self, dockIcon: true)
    }
}
