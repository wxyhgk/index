import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem?
    private let settings = AppSettings.shared
    /// 录制中每秒刷一次菜单里的「停止录制（mm:ss）」计时。
    private var recordingTimer: Timer?

    // MARK: - URL scheme（macshot://）

    private let urlRouter = URLCommandRouter()
    /// 冷启动经 URL 打开时，`application(_:open:)` 先于 `applicationDidFinishLaunching`
    /// 到达（URL 以 Apple Event 随启动派发）—— 此时注册表还没装配，先存起来，
    /// didFinishLaunching 末尾统一重放。
    private var launchFinished = false
    private var pendingURLs: [URL] = []

    func application(_ application: NSApplication, open urls: [URL]) {
        guard launchFinished else {
            pendingURLs.append(contentsOf: urls)
            return
        }
        urls.forEach { urlRouter.handle($0) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = ShotStore.shared          // 提前建库，避免第一次截图时卡顿
        CaptureActionRegistry.registerBuiltins(into: .shared)
        CapturePipeline.registerBuiltins(into: .shared)
        ToolbarRegistry.registerBuiltins(into: .shared)
        registerCaptureSources()

        setupStatusItem()
        setupHotKeys()

        AttributeBackfill.runIfNeeded()   // 给老截图补缺失的派生属性，后台串行，不影响启动
        ShelfController.cleanupDragFiles()   // 上次会话拖出的临时 PNG，此刻才能安全删

        settings.onShortcutsChanged = { [weak self] in self?.refreshHotKeys() }
        RecordingCoordinator.shared.onStateChanged = { [weak self] in
            self?.recordingStateChanged()
        }

        // 服务菜单：「用 MacShot 截图」（Info.plist 里的 NSServices 指到 captureService）。
        NSApp.servicesProvider = self

        if !ScreenRecordingPermission.isGranted {
            ScreenRecordingPermission.request()
        }

        // 服务已全部就绪，重放冷启动期间攒下的 URL 命令。
        launchFinished = true
        let queued = pendingURLs
        pendingURLs = []
        queued.forEach { urlRouter.handle($0) }
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    // MARK: - 捕获方式

    /// 延时秒数由闭包注入 —— 采集层不引用 AppSettings，配置只在这里交汇。
    /// `macshot://capture?delay=N` 的一次性覆盖也在这里消费，优先于设置值。
    private func registerCaptureSources() {
        let immediate = ImmediateScreenSource()
        CaptureSourceRegistry.shared.register(immediate)
        CaptureSourceRegistry.shared.register(DelayedScreenSource(wrapping: immediate) { [urlRouter] in
            urlRouter.consumeDelayOverride() ?? AppSettings.shared.captureDelay
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

        let record = NSMenuItem(title: "录屏…", action: #selector(toggleRecording), keyEquivalent: "")
        record.target = self
        record.tag = Tag.record
        menu.addItem(record)

        let gallery = NSMenuItem(title: "图库…", action: #selector(openGallery), keyEquivalent: "")
        gallery.target = self
        gallery.tag = Tag.gallery
        menu.addItem(gallery)

        // 穿透中的钉图收不到任何鼠标键盘事件（⌘T 按不进去），这里是唯一的解除入口。
        // 平时藏起来，menuNeedsUpdate 里按需显示。
        let liftPassthrough = NSMenuItem(
            title: "解除钉图穿透",
            action: #selector(liftPinPassthrough),
            keyEquivalent: ""
        )
        liftPassthrough.target = self
        liftPassthrough.tag = Tag.liftPassthrough
        liftPassthrough.isHidden = true
        menu.addItem(liftPassthrough)

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
        static let record = 4
        static let scrollCapture = 5
        static let liftPassthrough = 6
    }

    // MARK: - 快捷键

    private func setupHotKeys() {
        GlobalHotKeyCenter.shared.bind("capture", to: settings.captureShortcut) { [weak self] in
            self?.startCapture()
        }
        GlobalHotKeyCenter.shared.bind("capture-delayed", to: settings.delayedCaptureShortcut) { [weak self] in
            self?.startDelayedCapture()
        }
        GlobalHotKeyCenter.shared.bind("record", to: settings.recordingShortcut) { [weak self] in
            self?.toggleRecording()
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
        GlobalHotKeyCenter.shared.update("record", to: settings.recordingShortcut)
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

    @objc private func toggleRecording() {
        RecordingCoordinator.shared.toggle()
    }

    /// 采集期间再触发一次 = 完成（begin 内部处理）。
    @objc private func startScrollCapture() {
        ScrollCaptureController.shared.begin()
    }

    @objc private func openGallery() {
        GalleryWindowController.shared.show()
    }

    @objc private func liftPinPassthrough() {
        PinWindowController.liftAllPassthrough()
    }

    // MARK: - 录制状态

    private func recordingStateChanged() {
        refreshStatusIcon()
        recordingTimer?.invalidate()
        recordingTimer = nil

        if ScreenRecorder.shared.isRecording {
            // .common 模式：菜单开着（追踪运行循环）时计时也要走字。
            let timer = Timer(timeInterval: 1, repeats: true) { _ in
                Task { @MainActor in self.updateRecordingMenuItem() }
            }
            RunLoop.main.add(timer, forMode: .common)
            recordingTimer = timer
        }
        updateRecordingMenuItem()
    }

    /// 录制中换成红色圆点 —— 菜单栏是唯一常驻界面，必须一眼看出正在录。
    private func refreshStatusIcon() {
        let recording = ScreenRecorder.shared.isRecording
        var image = NSImage(
            systemSymbolName: recording ? "record.circle.fill" : "camera.viewfinder",
            accessibilityDescription: "MacShot"
        )
        if recording {
            image = image?.withSymbolConfiguration(.init(paletteColors: [.systemRed]))
            image?.isTemplate = false   // 模板渲染会抹掉红色
        }
        statusItem?.button?.image = image
    }

    private func updateRecordingMenuItem() {
        guard let item = statusItem?.menu?.item(withTag: Tag.record) else { return }
        if let startedAt = ScreenRecorder.shared.startedAt {
            let elapsed = Int(Date().timeIntervalSince(startedAt))
            let clock = String(format: "%02d:%02d", elapsed / 60, elapsed % 60)
            item.title = "停止录制（\(clock)）\t\(settings.recordingShortcut.displayString)"
        } else {
            item.title = "录屏…\t\(settings.recordingShortcut.displayString)"
        }
    }

    @objc private func openSettings() {
        SettingsWindowController.shared.show()
    }

    // MARK: - 服务菜单

    /// 「用 MacShot 截图」—— 无输入/输出类型，所以出现在所有 App 的「服务」菜单里。
    /// 签名是 NSServices 协定的固定形状，pasteboard/userData 用不上但不能省。
    @objc func captureService(
        _ pasteboard: NSPasteboard,
        userData: String,
        error: AutoreleasingUnsafeMutablePointer<NSString>
    ) {
        CaptureCoordinator.shared.begin()
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
        // 有穿透中的钉图才显示「解除钉图穿透」。
        menu.item(withTag: Tag.liftPassthrough)?.isHidden = !PinWindowController.hasPassthroughPins
        updateRecordingMenuItem()
    }
}
