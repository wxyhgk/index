import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Settings.registerDefaults()
        _ = ShotStore.shared          // 提前建库，避免第一次截图时卡顿

        setupStatusItem()
        setupHotKeys()

        if !CaptureEngine.hasPermission() {
            CaptureEngine.requestPermission()
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

        let capture = NSMenuItem(
            title: "截图",
            action: #selector(startCapture),
            keyEquivalent: "a"
        )
        capture.keyEquivalentModifierMask = [.control, .command]
        capture.target = self
        menu.addItem(capture)

        let gallery = NSMenuItem(
            title: "打开图库…",
            action: #selector(openGallery),
            keyEquivalent: "g"
        )
        gallery.keyEquivalentModifierMask = [.control, .command]
        gallery.target = self
        menu.addItem(gallery)

        menu.addItem(.separator())

        let clipboard = NSMenuItem(title: "截图后复制到剪贴板", action: #selector(toggleClipboard), keyEquivalent: "")
        clipboard.target = self
        clipboard.tag = 2
        menu.addItem(clipboard)

        let ocr = NSMenuItem(title: "自动识别文字（可搜索）", action: #selector(toggleOCR), keyEquivalent: "")
        ocr.target = self
        ocr.tag = 3
        menu.addItem(ocr)

        menu.addItem(.separator())

        let reveal = NSMenuItem(title: "在访达中显示存储位置", action: #selector(revealStorage), keyEquivalent: "")
        reveal.target = self
        menu.addItem(reveal)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 MacShot", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        return menu
    }

    private func setupHotKeys() {
        GlobalHotKeyCenter.shared.register(
            key: .a,
            modifiers: GlobalHotKeyCenter.Modifier.control | GlobalHotKeyCenter.Modifier.command
        ) { [weak self] in
            self?.startCapture()
        }

        GlobalHotKeyCenter.shared.register(
            key: .g,
            modifiers: GlobalHotKeyCenter.Modifier.control | GlobalHotKeyCenter.Modifier.command
        ) { [weak self] in
            self?.openGallery()
        }
    }

    // MARK: - 动作

    @objc private func startCapture() {
        CaptureCoordinator.shared.begin()
    }

    @objc private func openGallery() {
        GalleryWindowController.shared.show()
    }

    @objc private func toggleClipboard() { Settings.copyToClipboard.toggle() }
    @objc private func toggleOCR() { Settings.runOCR.toggle() }

    @objc private func revealStorage() {
        NSWorkspace.shared.activateFileViewerSelecting([ShotStore.shared.rootDirectory])
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.item(withTag: 2)?.state = Settings.copyToClipboard ? .on : .off
        menu.item(withTag: 3)?.state = Settings.runOCR ? .on : .off
    }
}
