import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem?
    private let settings = AppSettings.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = ShotStore.shared          // 提前建库，避免第一次截图时卡顿
        CaptureActionRegistry.registerBuiltins(into: .shared)
        CapturePipeline.registerBuiltins(into: .shared)
        ToolbarRegistry.registerBuiltins(into: .shared)

        setupStatusItem()
        setupHotKeys()

        AttributeBackfill.runIfNeeded()   // 给老截图补缺失的派生属性，后台串行，不影响启动

        settings.onShortcutsChanged = { [weak self] in self?.refreshHotKeys() }

        if !ScreenRecordingPermission.isGranted {
            ScreenRecordingPermission.request()
        }
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    // MARK: - 菜单栏

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(
            systemSymbolName: "camera.viewfinder",
            accessibilityDescription: "MacShot"
        )
        item.menu = buildMenu()
        statusItem = item
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self

        let capture = NSMenuItem(title: "截图", action: #selector(startCapture), keyEquivalent: "")
        capture.target = self
        capture.tag = Tag.capture
        menu.addItem(capture)

        let gallery = NSMenuItem(title: "图库…", action: #selector(openGallery), keyEquivalent: "")
        gallery.target = self
        gallery.tag = Tag.gallery
        menu.addItem(gallery)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(
            title: "设置…",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(
            title: "退出 MacShot",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))

        return menu
    }

    private enum Tag {
        static let capture = 1
        static let gallery = 2
    }

    // MARK: - 快捷键

    private func setupHotKeys() {
        GlobalHotKeyCenter.shared.bind("capture", to: settings.captureShortcut) { [weak self] in
            self?.startCapture()
        }
        GlobalHotKeyCenter.shared.bind("gallery", to: settings.galleryShortcut) { [weak self] in
            self?.openGallery()
        }
    }

    private func refreshHotKeys() {
        GlobalHotKeyCenter.shared.update("capture", to: settings.captureShortcut)
        GlobalHotKeyCenter.shared.update("gallery", to: settings.galleryShortcut)
    }

    // MARK: - 动作

    @objc private func startCapture() {
        CaptureCoordinator.shared.begin()
    }

    @objc private func openGallery() {
        GalleryWindowController.shared.show()
    }

    @objc private func openSettings() {
        SettingsWindowController.shared.show()
    }
}

extension AppDelegate: NSMenuDelegate {
    /// 菜单里显示当前生效的快捷键，改了设置立刻反映出来。
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.item(withTag: Tag.capture)?.title = "截图\t\(settings.captureShortcut.displayString)"
        menu.item(withTag: Tag.gallery)?.title = "图库…\t\(settings.galleryShortcut.displayString)"
    }
}
