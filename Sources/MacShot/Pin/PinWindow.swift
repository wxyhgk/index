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

    init(image: CGImage, shot: Shot?, anchor: CGRect) {
        self.image = image
        self.shot = shot

        let scale = anchor.width > 0 ? 1.0 : 1.0
        _ = scale
        let panel = PinPanel(
            contentRect: anchor.isEmpty
                ? CGRect(x: 200, y: 200, width: CGFloat(image.width) / 2, height: CGFloat(image.height) / 2)
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
        panel.isMovableByWindowBackground = true

        let view = PinImageView(image: image)
        view.onScrollZoom = { [weak self] delta in self?.applyZoom(delta) }
        view.onClose = { [weak self] in self?.close() }
        view.onCopy = { [weak self] in
            guard let self else { return }
            ImageCodec.copyToPasteboard(self.image)
        }
        view.onOpacityStep = { [weak self] step in self?.applyOpacity(step) }
        view.onEdit = { [weak self] in
            guard let shot = self?.shot else { return }
            EditorWindowController.open(shot: shot)
        }
        view.onOpenInGallery = { [weak self] in
            guard let shot = self?.shot else { return }
            GalleryWindowController.shared.show(selecting: shot)
        }
        panel.contentView = view

        Self.living.insert(self)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func applyZoom(_ delta: CGFloat) {
        guard let window else { return }
        let next = min(4.0, max(0.15, zoom * (1 + delta * 0.01)))
        guard abs(next - zoom) > 0.001 else { return }
        zoom = next

        let baseW = CGFloat(image.width) / 2
        let baseH = CGFloat(image.height) / 2
        let frame = window.frame
        // 以窗口中心为锚点缩放
        let newSize = CGSize(width: baseW * zoom, height: baseH * zoom)
        window.setFrame(
            CGRect(
                x: frame.midX - newSize.width / 2,
                y: frame.midY - newSize.height / 2,
                width: newSize.width,
                height: newSize.height
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

extension PinWindowController {
    /// 把一张图钉在它被截取的位置上。
    static func pin(image: CGImage, shot: Shot?, at globalRegion: CGRect) {
        let anchor: CGRect
        if globalRegion.width >= 20 && globalRegion.height >= 20 {
            anchor = globalRegion
        } else {
            anchor = .zero
        }
        let controller = PinWindowController(image: image, shot: shot, anchor: anchor)
        controller.showWindow(nil)
        controller.window?.orderFrontRegardless()
    }
}

// MARK: -

private final class PinPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private final class PinImageView: NSView {

    var onScrollZoom: ((CGFloat) -> Void)?
    var onClose: (() -> Void)?
    var onCopy: (() -> Void)?
    var onOpacityStep: ((CGFloat) -> Void)?
    var onOpenInGallery: (() -> Void)?
    var onEdit: (() -> Void)?

    private let cgImage: CGImage

    init(image: CGImage) {
        self.cgImage = image
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.25).cgColor
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.interpolationQuality = .high
        ctx.draw(cgImage, in: bounds)
    }

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            onOpacityStep?(event.scrollingDeltaY > 0 ? 0.05 : -0.05)
        } else {
            onScrollZoom?(event.scrollingDeltaY)
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53:                                            // ESC
            onClose?()
        case 8 where event.modifierFlags.contains(.command): // ⌘C
            onCopy?()
        default:
            super.keyDown(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onOpenInGallery?()
            return
        }
        // 交给 isMovableByWindowBackground 处理拖动
        super.mouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: "复制图片", action: #selector(copyImage), keyEquivalent: "").target = self
        menu.addItem(withTitle: "编辑标注…", action: #selector(editAnnotations), keyEquivalent: "").target = self
        menu.addItem(withTitle: "在图库中打开", action: #selector(openGallery), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "关闭", action: #selector(closePin), keyEquivalent: "").target = self
        return menu
    }

    @objc private func copyImage() { onCopy?() }
    @objc private func editAnnotations() { onEdit?() }
    @objc private func openGallery() { onOpenInGallery?() }
    @objc private func closePin() { onClose?() }
}
