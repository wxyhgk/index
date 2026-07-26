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
        registerCaptureSources()

        setupStatusItem()
        setupHotKeys()

        AttributeBackfill.runIfNeeded()   // 给老截图补缺失的派生属性，后台串行，不影响启动

        settings.onShortcutsChanged = { [weak self] in self?.refreshHotKeys() }

        if !ScreenRecordingPermission.isGranted {
            ScreenRecordingPermission.request()
        }
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    // MARK: - 捕获方式

    /// 延时秒数由闭包注入 —— 采集层不引用 AppSettings，配置只在这里交汇。
    private func registerCaptureSources() {
        let immediate = ImmediateScreenSource()
        CaptureSourceRegistry.shared.register(immediate)
        CaptureSourceRegistry.shared.register(DelayedScreenSource(wrapping: immediate) {
            AppSettings.shared.captureDelay
        })
    }

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

        let delayed = NSMenuItem(
            title: "延时截图",
            action: #selector(startDelayedCapture),
            keyEquivalent: ""
        )
        delayed.target = self
        delayed.tag = Tag.delayedCapture
        menu.addItem(delayed)

        let scroll = NSMenuItem(
            title: "滚动截图",
            action: #selector(startScrollCapture),
            keyEquivalent: ""
        )
        scroll.target = self
        scroll.tag = Tag.scrollCapture
        menu.addItem(scroll)

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
        static let delayedCapture = 3
        static let scrollCapture = 4
    }

    // MARK: - 快捷键

    private func setupHotKeys() {
        GlobalHotKeyCenter.shared.bind("capture", to: settings.captureShortcut) { [weak self] in
            self?.startCapture()
        }
        GlobalHotKeyCenter.shared.bind("capture-delayed", to: settings.delayedCaptureShortcut) { [weak self] in
            self?.startDelayedCapture()
        }
        GlobalHotKeyCenter.shared.bind("capture-scroll", to: settings.scrollCaptureShortcut) { [weak self] in
            self?.startScrollCapture()
        }
        GlobalHotKeyCenter.shared.bind("gallery", to: settings.galleryShortcut) { [weak self] in
            self?.openGallery()
        }
    }

    private func refreshHotKeys() {
        GlobalHotKeyCenter.shared.update("capture", to: settings.captureShortcut)
        GlobalHotKeyCenter.shared.update("capture-delayed", to: settings.delayedCaptureShortcut)
        GlobalHotKeyCenter.shared.update("capture-scroll", to: settings.scrollCaptureShortcut)
        GlobalHotKeyCenter.shared.update("gallery", to: settings.galleryShortcut)
    }

    // MARK: - 动作

    @objc private func startCapture() {
        CaptureCoordinator.shared.begin()
    }

    /// 倒计时期间再触发一次 = 取消（begin 内部处理）。
    @objc private func startDelayedCapture() {
        CaptureCoordinator.shared.begin(sourceID: CaptureSourceID.delayed)
    }

    /// 采集期间再触发一次 = 完成（begin 内部处理）。
    @objc private func startScrollCapture() {
        ScrollCaptureController.shared.begin()
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
        menu.item(withTag: Tag.delayedCapture)?.title =
            "延时截图（\(settings.captureDelay) 秒）\t\(settings.delayedCaptureShortcut.displayString)"
        menu.item(withTag: Tag.scrollCapture)?.title =
            "滚动截图\t\(settings.scrollCaptureShortcut.displayString)"
        menu.item(withTag: Tag.gallery)?.title = "图库…\t\(settings.galleryShortcut.displayString)"
    }
}
