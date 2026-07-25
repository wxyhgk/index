import AppKit

/// 钉图窗口。独立于主 App 的窗口控制器，生命周期自管。
@MainActor
final class PinWindowController: NSWindowController {

    private let image: CGImage
    private let shot: Shot?
    private var zoom: CGFloat = 1.0
    private var opacity: CGFloat = 1.0

    /// 全局持有，否则窗口会在 ARC 下立刻被回收。
    private static var living: Set<PinWindowController> = []

    /// 把一张图钉在它被截取的位置上。
    static func pin(image: CGImage, shot: Shot?, at globalRegion: CGRect) {
        let anchor: CGRect = (globalRegion.width >= 20 && globalRegion.height >= 20)
            ? globalRegion
            : .zero
        let controller = PinWindowController(image: image, shot: shot, anchor: anchor)
        controller.showWindow(nil)
        controller.window?.orderFrontRegardless()
    }

    private init(image: CGImage, shot: Shot?, anchor: CGRect) {
        self.image = image
        self.shot = shot

        let panel = PinPanel(
            contentRect: anchor.isEmpty
                ? CGRect(x: 200, y: 200,
                         width: CGFloat(image.width) / 2,
                         height: CGFloat(image.height) / 2)
                : anchor,
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
        // 不用 isMovableByWindowBackground：否则点悬停工具条会被当成拖窗口。
        // 拖动改由 PinImageView 在「没点到按钮」时手动发起。
        panel.isMovableByWindowBackground = false

        let view = PinImageView(image: image)
        view.onScrollZoom = { [weak self] delta in self?.applyZoom(delta) }
        view.onOpacityStep = { [weak self] step in self?.applyOpacity(step) }
        view.onAction = { [weak self] action in self?.perform(action) }
        panel.contentView = view

        Self.living.insert(self)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - 动作

    private func perform(_ action: PinAction) {
        switch action {
        case .edit:
            guard let shot else { return }
            EditorWindowController.open(shot: shot)
        case .copy:
            ImageCodec.copyToPasteboard(image)
        case .save:
            guard let shot else { return }
            CaptureActionPerformer.exportToDisk(image: image, shot: shot)
        case .gallery:
            guard let shot else { return }
            GalleryWindowController.shared.show(selecting: shot)
        case .close:
            close()
        }
    }

    private func applyZoom(_ delta: CGFloat) {
        guard let window else { return }
        let next = min(4.0, max(0.15, zoom * (1 + delta * 0.01)))
        guard abs(next - zoom) > 0.001 else { return }
        zoom = next

        // 以窗口中心为锚点缩放
        let size = CGSize(
            width: CGFloat(image.width) / 2 * zoom,
            height: CGFloat(image.height) / 2 * zoom
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
    }

    private func applyOpacity(_ step: CGFloat) {
        opacity = min(1.0, max(0.2, opacity + step))
        window?.alphaValue = opacity
    }

    override func close() {
        super.close()
        Self.living.remove(self)
    }
}

/// 无边框浮动面板。默认不能成为 key，但我们需要它接收键盘事件。
private final class PinPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
