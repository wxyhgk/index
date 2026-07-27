import AppKit

/// 钉图窗口。独立于主 App 的窗口控制器，生命周期自管。
///
/// 持有的是**未标注的底图 + 图层**，而不是合成好的位图 ——
/// 所以钉图之后继续画仍然是非破坏性的，改动作为新的修订入库。
@MainActor
final class PinWindowController: NSWindowController, CaptureActionHost {

    /// 穿透中的钉图索引。弱引用 —— 生命周期由 WindowRegistry 持有，
    /// 这里只是给菜单栏「解除钉图穿透」查询和遍历用，窗口析构后自动出表。
    private static let passthroughPins = NSHashTable<PinWindowController>.weakObjects()

    /// 菜单栏据此决定要不要显示「解除钉图穿透」。
    static var hasPassthroughPins: Bool { !passthroughPins.allObjects.isEmpty }

    /// 恢复所有穿透中的钉图。穿透后窗口收不到任何鼠标键盘事件，
    /// ⌘T 按不进去 —— 菜单栏这一项是唯一的解除入口。
    static func liftAllPassthrough() {
        for controller in passthroughPins.allObjects {
            controller.setPassthrough(false)
        }
    }

    private let base: CGImage
    private let shot: Shot?
    private var zoom: CGFloat = 1.0
    private var opacity: CGFloat = 1.0
    /// 鼠标穿透中：点击落到下层窗口，钉图只当参考图看。
    private var isPassthrough = false
    /// 上次落库的图层内容。比数量更可靠 —— 撤销一层再画一层，数量不变但内容变了。
    private var savedLayers: Layers<ImageSpace>

    private var imageView: PinImageView? { window?.contentView as? PinImageView }

    /// 把一张图钉在它被截取的位置上。
    static func pin(base: CGImage, layers: Layers<ImageSpace>, shot: Shot?, at globalRegion: CGRect) {
        let anchor: CGRect = (globalRegion.width >= 20 && globalRegion.height >= 20)
            ? globalRegion
            : .zero
        let controller = PinWindowController(base: base, layers: layers, shot: shot, anchor: anchor)
        // 钉图是浮动面板，不算「正经窗口」，不该让 App 跳出 Dock 图标。
        WindowRegistry.shared.present(controller, dockIcon: false, retain: true)
    }

    private init(base: CGImage, layers: Layers<ImageSpace>, shot: Shot?, anchor: CGRect) {
        self.base = base
        self.shot = shot
        self.savedLayers = layers

        // 图片区域保持在原位，窗口往下多出一条透明条带放工具条。
        let imageFrame = anchor.isEmpty
            ? CGRect(x: 200, y: 200,
                     width: CGFloat(base.width) / 2,
                     height: CGFloat(base.height) / 2)
            : anchor

        let panel = PinPanel(
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

        let view = PinImageView(base: base, layers: layers)
        view.onScrollZoom = { [weak self] delta in self?.applyZoom(delta) }
        view.onOpacityStep = { [weak self] step in self?.applyOpacity(step) }
        view.onAction = { [weak self] actionID in self?.perform(actionID) }
        view.onAnnotationsChanged = { [weak self] in self?.saveRevisionIfNeeded() }
        view.onToolbarHeightChanged = { [weak self] in self?.fitWindowToContent() }
        view.onTogglePassthrough = { [weak self] in
            guard let self else { return }
            self.setPassthrough(!self.isPassthrough)
        }
        // 套壳（frame）的倍率与元数据：钉图画布就是图像像素，壳的尺寸按 shot.scale
        // 缩放。从图库钉出时元数据已齐；截图直钉时 URL 可能还没回填（同覆盖层）。
        view.annotation.frameScale = max(1, shot?.scale ?? 1)
        view.annotation.frameDefaultTitle = shot?.windowTitle
        view.annotation.frameDefaultURL = shot?.sourceURL
        // 捕获信息层的元数据：App 名+版本、捕获时刻。没有 shot 时开信息栏
        // 只排得出日期（当下）—— 有什么排什么，效果开关不因此不可用。
        view.annotation.captureInfoDefaultApp = CaptureInfoSpec.appDescription(
            name: shot?.appName, version: shot?.appVersion
        )
        view.annotation.captureInfoDefaultDate = shot?.capturedAt
        panel.contentView = view

        fitWindowToContent()
    }

    /// 窗口高度 = 图片高度 + 工具条条带。图片顶边固定，条带在下方伸缩，
    /// 所以选中工具让工具条多出一行时，图片不会跳。
    private func fitWindowToContent() {
        guard let window, let view = imageView else { return }
        let strip = view.requiredStripHeight
        let frame = window.frame
        let imageHeight = CGFloat(base.height) / 2 * zoom
        let target = imageHeight + strip
        guard abs(frame.height - target) > 0.5 else { return }

        window.setFrame(
            CGRect(
                x: frame.minX,
                y: frame.maxY - target,
                width: frame.width,
                height: target
            ),
            display: true
        )
        window.invalidateShadow()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - 动作

    /// 钉图窗口不认识任何具体动作，只负责把上下文交给注册表里的实现。
    private func perform(_ actionID: String) {
        guard let action = CaptureActionRegistry.shared.action(id: actionID) else { return }
        let context = CaptureContext(
            base: base,
            layers: imageView?.allLayers ?? Layers(),
            shot: shot,
            region: nil,
            host: self
        )
        Task {
            do {
                try await action.perform(context)
            } catch {
                NSLog("[MacShot] 动作 \(actionID) 失败: \(error)")
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
        ShotStore.shared.appendRevision(shot: shot, layers: layers, note: "钉图上标注")
    }

    // MARK: - 窗口

    private func applyZoom(_ delta: CGFloat) {
        guard let window else { return }
        let next = min(4.0, max(0.15, zoom * (1 + delta * 0.01)))
        guard abs(next - zoom) > 0.001 else { return }
        zoom = next

        // 以窗口中心为锚点缩放；工具条条带不参与缩放，始终是固定高度。
        let strip = imageView?.requiredStripHeight ?? 0
        let size = CGSize(
            width: CGFloat(base.width) / 2 * zoom,
            height: CGFloat(base.height) / 2 * zoom + strip
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
    }

    private func applyOpacity(_ step: CGFloat) {
        opacity = min(1.0, max(0.2, opacity + step))
        window?.alphaValue = opacity
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
            Self.passthroughPins.add(self)
        } else {
            Self.passthroughPins.remove(self)
        }

        panel.ignoresMouseEvents = on
        panel.alphaValue = on ? min(opacity, 0.55) : opacity
        imageView?.isPassthrough = on
    }

    override func close() {
        saveRevisionIfNeeded()
        Self.passthroughPins.remove(self)
        super.close()
    }
}

/// 无边框浮动面板。默认不能成为 key，但我们需要它接收键盘事件。
private final class PinPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
