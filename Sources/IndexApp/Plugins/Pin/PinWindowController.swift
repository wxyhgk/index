import AppKit

/// 钉图窗口。独立于主 App 的窗口控制器，生命周期自管。
///
/// 持有的是**未标注的底图 + 图层**，而不是合成好的位图 ——
/// 所以钉图之后继续画仍然是非破坏性的，改动作为新的修订入库。
///
/// **窗口只装图片**：工具条是挂在下方的独立子窗口（`PinToolbarPanel`），
/// 尺寸只由「此刻有哪些控件可见」决定。钉图缩到多小、放到多大，工具条都不变。
@MainActor
final class PinWindowController: NSWindowController, CaptureActionHost, PinPassthroughControlling {

    private let base: CGImage
    private let shot: Shot?
    /// 修订链落库（钉图上标注）。注入而非硬引用单例，与同目录协调器对齐。
    private let shotStore: any ShotReading & ShotWriting
    /// 钉图窗口的设置切片：回车语义（键盘）+ 标注样式持久化（水印/底壳）。
    private let capture: any CapturePreferences
    private let annotationStyle: any AnnotationStylePreferences
    /// 钉出来时图片在屏幕上的原始尺寸，缩放的基准。
    private let naturalSize: CGSize
    private var zoom: CGFloat = 1.0
    private var opacity: CGFloat = 1.0
    /// 鼠标穿透中：点击落到下层窗口，钉图只当参考图看。
    private var isPassthrough = false
    /// 鼠标在钉图上（图片窗口或工具条窗口都算）。工具条据此在 0.45 / 1.0 之间切换。
    private var isHovering = false
    /// 上次落库的图层内容。比数量更可靠 —— 撤销一层再画一层，数量不变但内容变了。
    private var savedLayers: Layers<ImageSpace>
    private var actionExecution = ActionExecutionTracker()

    /// 工具条：独立的子窗口，不占图片窗口的任何空间。
    private let toolbarPanel = PinToolbarPanel()
    /// 父窗口 frame 变化的观察者 —— 子窗口跟着移动是自动的，但缩放和翻边要自己重算。
    private var frameObservers: [NSObjectProtocol] = []

    private var imageView: PinImageView? { window?.contentView as? PinImageView }

    /// 把一张图钉在它被截取的位置上。
    static func pin(
        base: CGImage,
        layers: Layers<ImageSpace>,
        shot: Shot?,
        at globalRegion: CGRect,
        capture: any CapturePreferences,
        annotationStyle: any AnnotationStylePreferences,
        moleculeSource: MoleculeSourceAttachment? = nil,
        shotStore: (any ShotReading & ShotWriting)? = nil
    ) {
        let anchor: CGRect = (globalRegion.width >= 20 && globalRegion.height >= 20)
            ? globalRegion
            : .zero
        let controller = PinWindowController(
            base: base,
            layers: layers,
            shot: shot,
            anchor: anchor,
            capture: capture,
            annotationStyle: annotationStyle,
            moleculeSource: moleculeSource,
            shotStore: shotStore ?? ShotStore.shared
        )
        // 钉图是浮动面板，不算「正经窗口」，不该让 App 跳出 Dock 图标。
        WindowRegistry.shared.present(controller, dockIcon: false, retain: true)
    }

    private init(
        base: CGImage,
        layers: Layers<ImageSpace>,
        shot: Shot?,
        anchor: CGRect,
        capture: any CapturePreferences,
        annotationStyle: any AnnotationStylePreferences,
        moleculeSource: MoleculeSourceAttachment?,
        shotStore: any ShotReading & ShotWriting
    ) {
        self.base = base
        self.shot = shot
        self.shotStore = shotStore
        self.savedLayers = layers
        self.capture = capture
        self.annotationStyle = annotationStyle

        // 窗口就是图片本身，不再为工具条预留条带。
        let imageFrame = anchor.isEmpty
            ? CGRect(x: 200, y: 200,
                     width: CGFloat(base.width) / 2,
                     height: CGFloat(base.height) / 2)
            : anchor
        self.naturalSize = imageFrame.size

        let panel = PinnedContentPanel(
            contentRect: imageFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init(window: panel)

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        // 不用 isMovableByWindowBackground：否则点工具条会被当成拖窗口。
        panel.isMovableByWindowBackground = false

        let view = PinImageView(
            base: base,
            layers: layers,
            capture: capture,
            annotationStyle: annotationStyle
        )
        let attachedMolecule = moleculeSource ?? shot.flatMap {
            shotStore.moleculeSource(for: $0)
        }
        if let attachedMolecule {
            view.moleculeSourceActions = MoleculeSourceActions(
                copyXYZ: {
                    Clipboard.copy(text: attachedMolecule.canonicalXYZ)
                },
                openInDefaultApp: { [weak self] in
                    do {
                        try MoleculeSourceFilePresenter.openWorkingCopy(
                            attachedMolecule,
                            shotID: shot?.id
                        )
                    } catch {
                        AppAlert.error(
                            "无法打开 XYZ 工作副本",
                            error: error,
                            host: self?.window
                        )
                    }
                },
                reopen3D: {
                    MacMoleculePinPresenter.shared.pinMolecule(
                        xyz: attachedMolecule.canonicalXYZ,
                        atomCount: attachedMolecule.atomCount
                    )
                }
            )
        }
        view.onScrollZoom = { [weak self] delta in self?.applyZoom(delta) }
        view.onOpacityStep = { [weak self] step in self?.applyOpacity(step) }
        view.onAction = { [weak self] actionID in self?.perform(actionID) }
        view.isActionExecuting = { [weak self] actionID in
            self?.actionExecution.isExecuting(actionID) ?? false
        }
        view.onAnnotationsChanged = { [weak self] in self?.saveRevisionIfNeeded() }
        view.onToolbarInvalidated = { [weak self] in self?.layoutToolbar() }
        view.onHoverChanged = { [weak self] in self?.refreshHover() }
        view.onTogglePassthrough = { [weak self] in
            guard let self else { return }
            self.setPassthrough(!self.isPassthrough)
        }
        // 效果层的注入上下文（钉图这一处，与覆盖层/编辑器同一契约）：
        // 钉图画布就是图像像素 —— 水印按底图宽烤字号、壳/信息栏按 shot.scale 缩放。
        // 从图库钉出时元数据已齐；截图直钉时 URL 可能还没回填（同覆盖层）；
        // 没有 shot 时开信息栏只排得出日期（当下）—— 有什么排什么，开关不因此不可用。
        view.annotation.effectContext = { [base, shot, annotationStyle] in
            var context = EffectContext()
            context.imagePixelWidth = Double(base.width)
            context.imagePixelHeight = Double(base.height)
            context.chromeScale = max(1, shot?.scale ?? 1)
            context.windowTitle = shot?.windowTitle
            context.sourceURL = shot?.sourceURL
            context.appDescription = CaptureInfoSpec.appDescription(
                name: shot?.appName, version: shot?.appVersion
            )
            context.capturedAt = shot?.capturedAt
            context.watermarkText = annotationStyle.watermarkText
            context.watermarkMode = annotationStyle.watermarkMode
            context.watermarkAlpha = annotationStyle.watermarkAlpha
            context.backdropPaddingRatio = annotationStyle.backdropPaddingRatio
            context.backdropCornerRatio = annotationStyle.backdropCornerRatio
            context.backdropShadowRatio = annotationStyle.backdropShadowRatio
            context.backdropShadowAlpha = annotationStyle.backdropShadowAlpha
            return context
        }
        panel.contentView = view

        // 工具条窗口只认这三件事：画什么（状态在图片视图那边）、点了谁来处理、
        // 鼠标进出。它自己不持有任何状态。
        toolbarPanel.toolbarView.context = { [weak view] in view?.toolbarContext }
        toolbarPanel.toolbarView.onActivate = { [weak view] control in
            view?.activateToolbarControl(control)
        }
        view.onToolbarKey = { [weak toolbarView = toolbarPanel.toolbarView] event in
            toolbarView?.handleKey(event) ?? false
        }
        view.onToolbarFocusClear = { [weak toolbarView = toolbarPanel.toolbarView] in
            toolbarView?.clearKeyboardFocus()
        }
        toolbarPanel.toolbarView.onHoverChanged = { [weak self] in self?.refreshHover() }
        toolbarPanel.toolbarView.onDragBy = { [weak self] delta in self?.moveWindow(by: delta) }
        toolbarPanel.toolbarView.onWidthStepped = { [weak view] in
            view?.needsDisplay = true
            view?.onAnnotationsChanged?()
            view?.onToolbarInvalidated?()
        }

        // 用户拖动钉图时子窗口自动跟着走，但贴屏幕下边缘要翻到上方；
        // 缩放改的是父窗口尺寸，工具条得重新居中。两种都靠这两条通知兜住。
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
            frameObservers.append(NotificationCenter.default.addObserver(
                forName: name, object: panel, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.layoutToolbar() }
            })
        }
    }

    deinit {
        frameObservers.forEach(NotificationCenter.default.removeObserver)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - 工具条窗口

    /// 挂成子窗口：父窗口移动时 AppKit 自动带着它走。
    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        attachToolbar()
    }

    private func attachToolbar() {
        guard let window, !isPassthrough else { return }
        if toolbarPanel.parent !== window {
            window.addChildWindow(toolbarPanel, ordered: .above)
        }
        layoutToolbar()
        refreshHover()
        // 刚挂上来（或穿透解除后重新挂上）时窗口的 alpha 还是默认值，补一次。
        applyToolbarAlpha()
    }

    /// 重算工具条窗口的尺寸与位置。**尺寸只跟内容走** ——
    /// 这里读的是「有哪些控件可见」，跟父窗口多大没有关系。
    private func layoutToolbar() {
        guard let window, toolbarPanel.parent != nil else { return }
        toolbarPanel.reposition(around: window)
    }

    /// 从工具条上拖 = 拖整个钉图（保住「拖条带挪窗口」的老手感）。
    private func moveWindow(by delta: CGSize) {
        guard let window else { return }
        let origin = window.frame.origin
        window.setFrameOrigin(CGPoint(x: origin.x + delta.width, y: origin.y - delta.height))
    }

    // MARK: - 悬停

    /// 悬停状态在两个窗口之间合并 —— 鼠标移到工具条上时工具条必须是亮的。
    ///
    /// 不用两个窗口各自的进出布尔量取或：跨窗口时两边的事件不保证同一轮到达（会闪一下暗），
    /// 而且工具条比图片窄时，鼠标从图片底边斜着离开会落进一块谁都收不到事件的空地，
    /// 悬停会卡在亮态。改成每次事件都按指针的实际位置判定。
    private var isPointerOnPin: Bool {
        guard let window, toolbarPanel.parent != nil else { return false }
        let point = NSEvent.mouseLocation
        let image = window.frame
        let toolbar = toolbarPanel.frame
        if image.insetBy(dx: 1, dy: 1).contains(point) { return true }
        if toolbar.insetBy(dx: 1, dy: 1).contains(point) { return true }
        // 两窗共享的那条边：退出事件报的坐标正好落在边界上，两个 inset 矩形都判不中，
        // 补一条窄桥把它接上。
        let edgeY = toolbar.midY < image.midY ? image.minY : image.maxY
        return CGRect(x: toolbar.minX, y: edgeY - 2, width: toolbar.width, height: 4)
            .contains(point)
    }

    private func refreshHover() {
        let hovered = isPointerOnPin
        guard hovered != isHovering else { return }
        isHovering = hovered
        applyToolbarAlpha()
    }

    /// 悬停才亮。整体透明度（⌘滚轮）也乘进去 —— 工具条以前住在窗口里，跟着一起淡。
    private func applyToolbarAlpha() {
        toolbarPanel.alphaValue = opacity * (isHovering ? 1.0 : 0.45)
    }

    // MARK: - 动作

    /// 钉图窗口不认识任何具体动作，只负责把上下文交给注册表里的实现。
    private func perform(_ actionID: String) {
        guard let action = CaptureActionRegistry.shared.action(id: actionID) else { return }
        guard actionExecution.begin(actionID) else {
            NSLog("[Index] 动作 \(actionID) 已在执行，忽略重复触发")
            return
        }
        layoutToolbar()
        let context = CaptureContext(
            base: base,
            layers: imageView?.allLayers ?? Layers(),
            shot: shot,
            region: nil,
            host: self
        )
        Task {
            defer {
                actionExecution.finish(actionID)
                layoutToolbar()
            }
            do {
                try await action.perform(context)
            } catch {
                NSLog("[Index] 动作 \(actionID) 失败: \(error)")
                AppAlert.error("\(action.title)失败", error: error, host: window)
            }
        }
    }

    /// CaptureActionHost —— 「关闭」动作靠它作用回窗口自己。
    func dismiss() {
        close()
    }

    /// 钉图上新画的标注也要进修订链 —— 和截图时画的、图库里改的走同一条链。
    private func saveRevisionIfNeeded() {
        guard let shot, let view = imageView else { return }
        let layers = view.allLayers
        guard layers != savedLayers else { return }
        savedLayers = layers
        shotStore.appendRevision(shot: shot, layers: layers, note: "钉图上标注")
    }

    // MARK: - 窗口

    private func applyZoom(_ delta: CGFloat) {
        guard let window else { return }
        let next = min(4.0, max(0.15, zoom * (1 + delta * 0.01)))
        guard abs(next - zoom) > 0.001 else { return }
        zoom = next

        // 以窗口中心为锚点缩放。窗口里只有图片，工具条在另一个窗口上，
        // 缩放不会牵动它 —— 它只是重新居中到新的下边缘（见 layoutToolbar）。
        let size = CGSize(
            width: naturalSize.width * zoom,
            height: naturalSize.height * zoom
        )
        let frame = window.frame
        window.setFrame(
            CGRect(
                x: frame.midX - size.width / 2,
                y: frame.midY - size.height / 2,
                width: size.width,
                height: size.height
            ),
            display: true,
            animate: false
        )
        window.invalidateShadow()
        // 选字层跟随缩放：bounds 变了，归一化坐标需重贴，分析结果复用（像素未变）
        imageView?.didZoom()
    }

    private func applyOpacity(_ step: CGFloat) {
        opacity = min(1.0, max(0.2, opacity + step))
        window?.alphaValue = opacity
        applyToolbarAlpha()
    }

    // MARK: - 鼠标穿透

    /// ⌘T 切换。开：窗口不收鼠标、压暗到 0.55、边框变虚线（视觉提示「现在点不到我」）；
    /// 关：恢复用户自己调过的透明度。
    private func setPassthrough(_ on: Bool) {
        guard isPassthrough != on, let panel = window else { return }
        isPassthrough = on

        if on {
            // 文字输入态收不到后续按键了，先落库结束。
            imageView?.annotation.endTextEditing()
            PinPassthroughRegistry.shared.register(self)
        } else {
            PinPassthroughRegistry.shared.unregister(self)
        }

        panel.ignoresMouseEvents = on
        panel.alphaValue = on ? min(opacity, 0.55) : opacity
        imageView?.isPassthrough = on

        // 工具条整个收起来 —— 穿透中它也点不到，留在屏幕上只会误导。
        // `ignoresMouseEvents` 不会传染给子窗口，必须自己下线。
        if on {
            isHovering = false
            toolbarPanel.toolbarView.clearToolTips()
            panel.removeChildWindow(toolbarPanel)
            toolbarPanel.orderOut(nil)
        } else {
            attachToolbar()
        }
    }

    override func close() {
        saveRevisionIfNeeded()
        imageView?.teardownLiveText()
        PinPassthroughRegistry.shared.unregister(self)
        toolbarPanel.toolbarView.clearToolTips()
        window?.removeChildWindow(toolbarPanel)
        toolbarPanel.orderOut(nil)
        super.close()
    }

    func setPinPassthrough(_ enabled: Bool) {
        setPassthrough(enabled)
    }
}
