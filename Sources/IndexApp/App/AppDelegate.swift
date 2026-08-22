import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem?
    private let settings: any StyleStore
    private let shotStore: any ShotReading & ShotWriting & ShotObserving
    private let pipeline: CapturePipeline
    private let clipboardReader: any ClipboardReading
    private let moleculePinner: any MoleculePinning
    /// 录制中每秒刷一次菜单里的「停止录制（mm:ss）」计时。
    private var recordingTimer: Timer?

    // MARK: - URL scheme（index://；兼容 macshot://）

    private let urlRouter: URLCommandRouter

    init(
        settings: (any StyleStore)? = nil,
        shotStore: (any ShotReading & ShotWriting & ShotObserving)? = nil,
        pipeline: CapturePipeline? = nil,
        urlRouter: URLCommandRouter? = nil,
        clipboardReader: (any ClipboardReading)? = nil,
        moleculePinner: (any MoleculePinning)? = nil
    ) {
        self.settings = settings ?? AppSettings.shared
        self.shotStore = shotStore ?? ShotStore.shared
        self.pipeline = pipeline ?? CapturePipeline.shared
        self.urlRouter = urlRouter ?? URLCommandRouter()
        self.clipboardReader = clipboardReader ?? MacClipboard.shared
        self.moleculePinner = moleculePinner ?? MacMoleculePinPresenter.shared
        super.init()
    }

    /// 预览/测试可用 Fake
    static var preview: AppDelegate {
        let fakeStore = FakeShotStore.preview
        let fakeStyle = FakeStyleStore()
        return AppDelegate(
            settings: fakeStyle,
            shotStore: fakeStore,
            pipeline: CapturePipeline(writer: ShotStoreAttributeWriter(store: fakeStore)),
            urlRouter: .preview
        )
    }
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
        _ = shotStore          // 提前建库，避免第一次截图时卡顿
        CaptureActionRegistry.registerBuiltins(into: .shared, styleStore: settings)
        ToolbarRegistry.registerBuiltins(into: .shared)
        GalleryDestinationRegistry.registerBuiltins(into: .shared)
        PluginRegistry.registerBuiltins()
        ImageExporter.nameTemplateProvider = { AppSettings.shared.export.exportNameTemplate }

        // 插件激活：截图/录屏/钉图/暂存架各是一个动作包。
        // 截图后处理器（OCR/分类/Markdown 生成...）由 CapturePlugin 注册到 pipeline。
        let pluginCtx = PluginContext(
            settings: settings,
            shotStore: shotStore,
            pipeline: pipeline,
            actionRegistry: .shared,
            toolbarRegistry: .shared,
            hotKeyCenter: .shared,
            pluginManager: .shared,
            pluginRegistry: .shared,
            openShot: { shot in
                GalleryWindowController.shared.showEditor(for: shot)
            }
        )
        // 插件激活：按 enabledPluginIDs 过滤（空列表 = 全部启用）。
        let pluginManager = PluginManager.shared
        let allPlugins: [any Plugin] = [
            CapturePlugin(),
            RecordingPlugin(),
            PinPlugin(),
            ShelfPlugin(),
            AgentPlugin.shared,
        ]
        let enabledIDs = settings.enabledPluginIDs
        for plugin in allPlugins {
            if enabledIDs.isEmpty || enabledIDs.contains(plugin.id) {
                pluginManager.activate(plugin, ctx: pluginCtx)
            }
        }

        // 3D 窗口只负责产生当前相机视角；图片落库、来源附件与普通钉图的编排
        // 留在 App 层，避免 Platform 反向依赖 Storage / Pin。
        moleculePinner.configureFreezeHandler { [weak self] snapshot, source in
            guard let self else { return }
            try self.freezeMolecule(snapshot, source: source)
        }

        // 修订落库后重画缩略图所需的两件事，在这里接线 ——
        // Storage 不许认识 Render（渲染）和 UI（缓存），所以由编排层注入。
        if let store = shotStore as? ShotStore {
            store.revisionThumbnailRenderer = { base, layers in
                LayerRenderer.render(base: base, layers: layers)
            }
            store.thumbnailInvalidator = { shot in
                ThumbnailLoader.shared.remove(forKey: shot.sha256)
            }
        }
        // 选区后分派到录屏/长截图：闭包注入，CaptureCoordinator 不认识具体插件类型。
        CaptureCoordinator.shared.recordHandler = { region, display in
            RecordingCoordinator.shared.startDirectly(region: region, display: display)
        }
        CaptureCoordinator.shared.scrollHandler = { region, display in
            ScrollCaptureController.shared.begin(with: region, display: display)
        }
        CaptureCoordinator.shared.isOtherCaptureActive = {
            ScreenRecorder.shared.isRecording || RecordingCoordinator.shared.isSelecting
        }

        registerCaptureSources()

        setupMainMenu()
        setupStatusItem()
        setupHotKeys()

        AttributeBackfill.runIfNeeded(styleStore: settings, store: shotStore)   // 给老截图补缺失的派生属性，后台串行，不影响启动
        StorageJanitor.runIfNeeded(settings: settings, store: shotStore)      // 清理过期且无价值（未收藏、未标注）的旧截图
        ShelfController.cleanupDragFiles()   // 上次会话拖出的临时 PNG，此刻才能安全删

        if let appSettings = settings as? AppSettings {
            appSettings.onShortcutsChanged = { [weak self] in self?.refreshHotKeys() }
            appSettings.onClipboardHistoryChanged = { [weak self] in
                self?.applyClipboardHistorySettings()
            }
        }
        applyClipboardHistorySettings()
        RecordingCoordinator.shared.onStateChanged = { [weak self] in
            self?.recordingStateChanged()
        }

        // 服务菜单：「用 Index 截图」（Info.plist 里的 NSServices 指到 captureService）。
        NSApp.servicesProvider = self

        // 启动时不触碰屏幕捕获授权链。当前 macOS 15.3.1 现场的 replayd
        // 会在 ReplayKit/TCC 授权处理里连续崩溃；即便只是 preflight，也没有
        // 必要让一次普通的 App 启动介入这条链。首次授权由用户真正发起截图时
        // 的 CaptureCoordinator 按需处理。

        // 服务已全部就绪，重放冷启动期间攒下的 URL 命令。
        launchFinished = true
        let queued = pendingURLs
        pendingURLs = []
        queued.forEach { urlRouter.handle($0) }

        // Hook 事件（= Emacs after-init-hook）：插件挂 appLaunch 就能响应。
        Task {
            await HookRegistry.shared.fire(
                .appLaunch,
                context: HookContext(event: .appLaunch, shotID: nil, image: nil, metadata: nil, writer: nil)
            )
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Hook 事件（= Emacs before-quit-hook）：插件挂 appWillQuit 就能响应。
        Task {
            await HookRegistry.shared.fire(
                .appWillQuit,
                context: HookContext(event: .appWillQuit, shotID: nil, image: nil, metadata: nil, writer: nil)
            )
        }
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    // MARK: - 捕获方式

    /// 延时秒数由闭包注入 —— 采集层不引用 AppSettings，配置只在这里交汇。
    /// `index://capture?delay=N` 的一次性覆盖也在这里消费，优先于设置值。
    private func registerCaptureSources() {
        let immediate = ImmediateScreenSource(capturer: MacScreenCapturer.shared)
        CaptureSourceRegistry.shared.register(immediate)
        CaptureSourceRegistry.shared.register(DelayedScreenSource(wrapping: immediate) { [urlRouter, settings] in
            urlRouter.consumeDelayOverride() ?? settings.captureDelay
        })
    }

    // MARK: - 菜单栏

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(
            systemSymbolName: "camera.viewfinder",
            accessibilityDescription: "Index"
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

        // 录制中才出现：录制态显示「暂停录制」，暂停态显示「继续录制」。
        let recordPause = NSMenuItem(
            title: "暂停录制",
            action: #selector(togglePauseRecording),
            keyEquivalent: ""
        )
        recordPause.target = self
        recordPause.tag = Tag.recordPause
        recordPause.isHidden = true
        menu.addItem(recordPause)

        let gallery = NSMenuItem(title: "图库…", action: #selector(openGallery), keyEquivalent: "")
        gallery.target = self
        gallery.tag = Tag.gallery
        menu.addItem(gallery)

        let molecule = NSMenuItem(
            title: "从剪贴板钉住 3D 分子",
            action: #selector(pinMoleculeFromClipboard),
            keyEquivalent: ""
        )
        molecule.target = self
        molecule.tag = Tag.moleculePin
        menu.addItem(molecule)

        let clipboardHistory = NSMenuItem(
            title: "剪贴板历史…",
            action: #selector(toggleClipboardHistory),
            keyEquivalent: ""
        )
        clipboardHistory.target = self
        clipboardHistory.tag = Tag.clipboardHistory
        menu.addItem(clipboardHistory)

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
            title: "退出 Index",
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
        static let recordPause = 7
        static let moleculePin = 8
        static let clipboardHistory = 9
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
        GlobalHotKeyCenter.shared.bind("pin-molecule", to: settings.moleculePinShortcut) { [weak self] in
            self?.pinMoleculeFromClipboard()
        }
        GlobalHotKeyCenter.shared.bind("clipboard-history", to: settings.clipboardHistoryShortcut) { [weak self] in
            self?.toggleClipboardHistory()
        }
        GlobalHotKeyCenter.shared.bind("search-panel", to: settings.searchPanelShortcut) { [weak self] in
            self?.toggleSearchPanel()
        }
        GlobalHotKeyCenter.shared.bind("quick-note", to: settings.quickNoteShortcut) { [weak self] in
            self?.toggleQuickNote()
        }
        GlobalHotKeyCenter.shared.bind("agent", to: settings.agentShortcut) { [weak self] in
            self?.toggleAgent()
        }
    }

    private func refreshHotKeys() {
        GlobalHotKeyCenter.shared.update("capture", to: settings.captureShortcut)
        GlobalHotKeyCenter.shared.update("capture-delayed", to: settings.delayedCaptureShortcut)
        GlobalHotKeyCenter.shared.update("record", to: settings.recordingShortcut)
        GlobalHotKeyCenter.shared.update("capture-scroll", to: settings.scrollCaptureShortcut)
        GlobalHotKeyCenter.shared.update("gallery", to: settings.galleryShortcut)
        GlobalHotKeyCenter.shared.update("pin-molecule", to: settings.moleculePinShortcut)
        GlobalHotKeyCenter.shared.update("clipboard-history", to: settings.clipboardHistoryShortcut)
        GlobalHotKeyCenter.shared.update("search-panel", to: settings.searchPanelShortcut)
        GlobalHotKeyCenter.shared.update("quick-note", to: settings.quickNoteShortcut)
        GlobalHotKeyCenter.shared.update("agent", to: settings.agentShortcut)
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

    @objc private func togglePauseRecording() {
        RecordingCoordinator.shared.pauseOrResume()
    }

    /// 采集期间再触发一次 = 完成（begin 内部处理）。
    @objc private func startScrollCapture() {
        ScrollCaptureController.shared.begin()
    }

    @objc private func openGallery() {
        GalleryWindowController.shared.show()
    }

    @objc private func pinMoleculeFromClipboard() {
        guard let text = clipboardReader.readText(), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            AppAlert.error(
                "无法创建 3D 分子钉图",
                message: "请先复制标准 XYZ 文本，或复制若干行“元素 X Y Z”坐标。"
            )
            return
        }
        do {
            let molecule = try MoleculeXYZ.parse(text)
            moleculePinner.pinMolecule(xyz: molecule.canonicalText, atomCount: molecule.atomCount)
        } catch {
            AppAlert.error("无法创建 3D 分子钉图", error: error)
        }
    }

    @objc private func toggleClipboardHistory() {
        ClipboardHistoryCoordinator.shared.togglePanel()
    }

    @objc private func toggleSearchPanel() {
        SearchPanelCoordinator.shared.togglePanel()
    }

    @objc private func toggleQuickNote() {
        QuickNoteCoordinator.shared.toggle()
    }

    @objc private func toggleAgent() {
        AgentCoordinator.shared.toggle()
    }

    /// 按设置启停剪贴板监听 + 清理过期条目。
    private func applyClipboardHistorySettings() {
        if settings.clipboardHistoryEnabled {
            ClipboardHistoryStore.shared.prune(olderThanDays: settings.clipboardHistoryRetentionDays)
            ClipboardHistoryCoordinator.shared.start()
        } else {
            ClipboardHistoryCoordinator.shared.stop()
        }
    }

    private func freezeMolecule(
        _ snapshot: MoleculeFreezeSnapshot,
        source: MoleculeSourceAttachment
    ) throws {
        var metadata = CaptureMetadata()
        metadata.globalRegion = snapshot.globalRegion
        metadata.scale = snapshot.scale
        metadata.appName = "Index 3D 分子"
        metadata.appBundleID = Bundle.main.bundleIdentifier
        metadata.appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        metadata.appBuild = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        let moleculeComment = source.canonicalXYZ
            .split(separator: "\n", omittingEmptySubsequences: false)
            .dropFirst()
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        metadata.windowTitle = moleculeComment.flatMap { $0.isEmpty ? nil : $0 } ?? "3D 分子"

        if let screen = Geometry.screen(containing: CGPoint(
            x: snapshot.globalRegion.midX,
            y: snapshot.globalRegion.midY
        )) {
            metadata.displayID = Geometry.displayID(of: screen)
            metadata.displayName = screen.localizedName
        }

        let shot = try shotStore.save(image: snapshot.image, metadata: metadata)
        do {
            try shotStore.attachMoleculeSource(source, to: shot)
        } catch {
            // 来源附件是这类 Shot 的产品契约。写失败就撤销图片记录，不能留下
            // 一个工具栏里再也找不回 XYZ 的半成品。
            shotStore.delete(shot)
            throw error
        }

        if let shotID = shot.id {
            pipeline.run(
                shotID: shotID,
                originalURL: shotStore.originalURL(for: shot),
                appBundleID: metadata.appBundleID,
                metadata: ShotMetadata(from: shot)
            )
        }
        PinWindowController.pin(
            base: snapshot.image,
            layers: Layers(),
            shot: shot,
            at: snapshot.globalRegion,
            capture: settings,
            annotationStyle: settings,
            moleculeSource: source
        )
    }

    @objc private func liftPinPassthrough() {
        PinPassthroughRegistry.shared.liftAll()
    }

    // MARK: - 录制状态

    private func recordingStateChanged() {
        refreshStatusIcon()
        recordingTimer?.invalidate()
        recordingTimer = nil

        // 暂停中不走字，计时器也不必转。
        if ScreenRecorder.shared.isRecording, !ScreenRecorder.shared.isPaused {
            // .common 模式：菜单开着（追踪运行循环）时计时也要走字。
            let timer = Timer(timeInterval: 1, repeats: true) { _ in
                Task { @MainActor in self.updateRecordingMenuItem() }
            }
            RunLoop.main.add(timer, forMode: .common)
            recordingTimer = timer
        }
        updateRecordingMenuItem()
    }

    /// 录制中换成红色圆点、暂停中换成黄色暂停标 ——
    /// 菜单栏是唯一常驻界面，必须一眼看出当前状态。
    private func refreshStatusIcon() {
        let recorder = ScreenRecorder.shared
        let symbolName: String
        let tint: NSColor?
        if recorder.isPaused {
            symbolName = "pause.circle.fill"
            tint = .systemYellow
        } else if recorder.isRecording {
            symbolName = "record.circle.fill"
            tint = .systemRed
        } else {
            symbolName = "camera.viewfinder"
            tint = nil
        }
        var image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Index")
        if let tint {
            image = image?.withSymbolConfiguration(.init(paletteColors: [tint]))
            image?.isTemplate = false   // 模板渲染会抹掉颜色
        }
        statusItem?.button?.image = image
    }

    private func updateRecordingMenuItem() {
        guard let menu = statusItem?.menu, let item = menu.item(withTag: Tag.record) else { return }
        let pauseItem = menu.item(withTag: Tag.recordPause)
        let recorder = ScreenRecorder.shared
        if recorder.isRecording {
            // elapsed 只累计录制段，暂停期不走字。
            let elapsed = Int(recorder.elapsed)
            let clock = String(format: "%02d:%02d", elapsed / 60, elapsed % 60)
            let suffix = recorder.isPaused ? "，已暂停" : ""
            item.title = "停止录制（\(clock)\(suffix)）\t\(settings.recordingShortcut.displayString)"
            pauseItem?.isHidden = false
            pauseItem?.title = recorder.isPaused ? "继续录制" : "暂停录制"
        } else {
            item.title = "录屏…\t\(settings.recordingShortcut.displayString)"
            pauseItem?.isHidden = true
        }
    }

    /// 设置不再是独立窗口，而是图库窗口的一个模式 —— 弹出图库并切过去。
    /// 与「单窗口多模式」的整体设计一致，也省掉一个要管生命周期的窗口。
    @objc private func openSettings() {
        GalleryWindowController.shared.show()
        GalleryWindowController.shared.mode.openSettings()
    }

    // MARK: - 主菜单（Edit → Copy / Select All 走 responder chain）

    /// LSUIElement 常驻时菜单栏仅在 `.regular`（图库/设置窗口期）可见，
    /// 但键等价（⌘C/⌘A）始终生效。Edit 项用标准 `copy:`/`selectAll:`，
    /// 文本框聚焦时由 NSTextView 自行处理，图库网格时冒泡到 GalleryWindowController。
    private func setupMainMenu() {
        let mainMenu = NSMenu()

        // App 菜单（至少要有一个，系统才认为 mainMenu 合法）
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "关于 Index", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "退出 Index", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appMenuItem.submenu = appMenu

        // Edit 菜单：Copy / Select All 走标准 selector，validation 由窗口控制器决定
        // copy: 声明在 NSText，用其 selector 避免直接写字符串
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(title: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "全选", action: #selector(NSResponder.selectAll(_:)), keyEquivalent: "a"))
        editMenuItem.submenu = editMenu

        // Window 菜单：让系统自动管理窗口列表
        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "Window")
        NSApp.windowsMenu = windowMenu
        windowMenuItem.submenu = windowMenu

        NSApp.mainMenu = mainMenu
    }

    // Edit 菜单的实际执行与校验兜底（responder chain 未命中时由 App 兜住）
    @objc func copy(_ sender: Any?) {
        // 先让第一响应者的 NSTextView 处理文字复制，若未处理再复制图片
        if let textView = NSApp.keyWindow?.firstResponder as? NSTextView,
           textView.selectedRange().length > 0 {
            return // 交由 NSTextView 自身的 copy: 处理
        }
        guard GalleryWindowController.shared.mode.mode == .library else { return }
        guard !GalleryWindowController.shared.selection.selectedIDs.isEmpty else { return }
        guard !GalleryWindowController.shared.batchActivity.isBusy else { return }
        let displayed = GalleryViewModel.displayShots(for: shotStore)
        if let shots = GalleryBatch.loadedSelectedShots(
            displayedShots: displayed,
            reader: shotStore
        ) {
            GalleryBatch.copyImages(shots, reader: shotStore)
        } else {
            Task { [shotStore] in
                _ = await GalleryBatch.copySelectedImages(reader: shotStore)
            }
        }
    }

    @objc func selectAll(_ sender: Any?) {
        // 文本框内有焦点时让其自行全选
        if NSApp.keyWindow?.firstResponder is NSTextView { return }
        guard GalleryWindowController.shared.mode.mode == .library else { return }
        Task { [shotStore] in
            let ids = await GalleryViewModel.allMatchingIDs(for: shotStore)
            GalleryWindowController.shared.selection.selectAll(ids)
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(NSText.copy(_:)):
            if let tv = NSApp.keyWindow?.firstResponder as? NSTextView, tv.selectedRange().length > 0 {
                return true
            }
            return GalleryWindowController.shared.mode.mode == .library && !GalleryWindowController.shared.selection.selectedIDs.isEmpty
        case #selector(NSResponder.selectAll(_:)):
            if NSApp.keyWindow?.firstResponder is NSTextView { return true }
            return GalleryWindowController.shared.mode.mode == .library
        default:
            return true
        }
    }

    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if let menuItem = item as? NSMenuItem {
            switch menuItem.action {
            case #selector(NSText.copy(_:)):
                if let tv = NSApp.keyWindow?.firstResponder as? NSTextView, tv.selectedRange().length > 0 {
                    return true
                }
                return GalleryWindowController.shared.mode.mode == .library && !GalleryWindowController.shared.selection.selectedIDs.isEmpty
            case #selector(NSResponder.selectAll(_:)):
                if NSApp.keyWindow?.firstResponder is NSTextView { return true }
                return GalleryWindowController.shared.mode.mode == .library
            default: break
            }
        }
        return true
    }

    // MARK: - 服务菜单

    /// 「用 Index 截图」—— 无输入/输出类型，所以出现在所有 App 的「服务」菜单里。
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
        menu.item(withTag: Tag.moleculePin)?.title =
            "从剪贴板钉住 3D 分子\t\(settings.moleculePinShortcut.displayString)"
        // 有穿透中的钉图才显示「解除钉图穿透」。
        menu.item(withTag: Tag.liftPassthrough)?.isHidden =
            !PinPassthroughRegistry.shared.hasPassthroughPins
        updateRecordingMenuItem()
    }
}
