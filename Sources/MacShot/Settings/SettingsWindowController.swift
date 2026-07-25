import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {

    static let shared = SettingsWindowController()

    private init() {
        let hosting = NSHostingController(rootView: SettingsView())
        let window = NSWindow(contentViewController: hosting)
        window.title = "MacShot 设置"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 500, height: 460))
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        // 菜单栏 App 平时是 .accessory，开窗口时切成 .regular 才有正常的窗口行为。
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        let hasOther = NSApp.windows.contains {
            $0.isVisible && $0 !== window && !($0 is NSPanel)
        }
        if !hasOther {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
