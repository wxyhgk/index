import AppKit

/// 暂存栏上的一张卡片：合成后的截图缩略图 + 底部来源信息条。
///
/// 交互：拖出 = 生成 PNG 文件；双击 = 打开图库定位到这张；
/// 悬停出现关闭按钮；15 秒无操作自动淡出（悬停和拖拽期间暂停计时）。
/// 面板不抢焦点也永远不成为 key —— ⎋ 等按键与它无关。
@MainActor
final class ShelfCardController: NSWindowController {

    private static let cardWidth: CGFloat = 240
    private static let autoCloseDelay: TimeInterval = 15

    private let previewImage: CGImage
    private let shot: Shot?
    /// 仅在用户真的开始文件拖拽时解析全尺寸成品。普通的 15 秒展示期只持有缩略图。
    private let fullImageProvider: @MainActor () -> CGImage?
    private let galleryPresenter: any GalleryPresenting
    private var autoCloseTimer: Timer?
    private var isHovering = false
    private var isDragging = false
    private var isClosing = false
    /// 已写出的拖拽临时文件。同一张卡多次拖出复用同一份。
    private var dragFileURL: URL?

    init(
        previewImage: CGImage,
        shot: Shot?,
        fullImageProvider: @escaping @MainActor () -> CGImage?,
        galleryPresenter: (any GalleryPresenting)? = nil
    ) {
        self.previewImage = previewImage
        self.shot = shot
        self.fullImageProvider = fullImageProvider
        self.galleryPresenter = galleryPresenter ?? GalleryWindowController.shared

        // 卡片宽度固定，缩略图高度按图片比例走，过宽/过高的截图夹在合理区间里。
        let aspect = CGFloat(previewImage.height) / CGFloat(max(previewImage.width, 1))
        let thumbHeight = min(170, max(60, (Self.cardWidth * aspect).rounded()))
        let size = CGSize(width: Self.cardWidth, height: thumbHeight + ShelfCardView.barHeight)

        let panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init(window: panel)

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = false
        // 淡入前先全透明，避免 orderFront 的一瞬闪现。
        panel.alphaValue = 0

        let view = ShelfCardView(image: previewImage, caption: Self.caption(for: shot))
        view.onClose = { [weak self] in self?.fadeOutAndClose() }
        view.onDoubleClick = { [weak self] in self?.openInGallery() }
        view.onHoverChanged = { [weak self] hovering in
            self?.isHovering = hovering
            self?.updateTimerState()
        }
        view.onDragStateChanged = { [weak self] dragging in
            self?.isDragging = dragging
            self?.updateTimerState()
        }
        view.makeDragFile = { [weak self] in self?.makeDragFile() }
        view.onDragCompleted = { [weak self] in self?.fadeOutAndClose() }
        panel.contentView = view

        scheduleAutoClose()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// 底部信息条：「App 名 · 时间」。
    private static func caption(for shot: Shot?) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let time = formatter.string(from: shot?.capturedAt ?? Date())
        guard let app = shot?.appName, !app.isEmpty else { return time }
        return "\(app) · \(time)"
    }

    // MARK: - 出场 / 退场

    func fadeIn() {
        guard let window else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            window.animator().alphaValue = 1
        }
    }

    private func fadeOutAndClose() {
        guard !isClosing, let window else { return }
        isClosing = true
        autoCloseTimer?.invalidate()
        autoCloseTimer = nil
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.3
            window.animator().alphaValue = 0
        }, completionHandler: {
            // 强持有 self 到关窗为止 —— 淡出中途注册表不会替我们续命。
            self.close()
        })
    }

    override func close() {
        autoCloseTimer?.invalidate()
        autoCloseTimer = nil
        super.close()
    }

    // MARK: - 自动淡出

    private func scheduleAutoClose() {
        autoCloseTimer?.invalidate()
        autoCloseTimer = Timer.scheduledTimer(
            withTimeInterval: Self.autoCloseDelay,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor in self?.fadeOutAndClose() }
        }
    }

    /// 悬停或拖拽期间不计时；两者都结束后重新给满 15 秒。
    private func updateTimerState() {
        if isHovering || isDragging {
            autoCloseTimer?.invalidate()
            autoCloseTimer = nil
        } else if autoCloseTimer == nil, !isClosing {
            scheduleAutoClose()
        }
    }

    // MARK: - 交互

    private func openInGallery() {
        galleryPresenter.show(selecting: shot)
    }

    /// 拖拽发起时把合成图写成临时 PNG。文件名与「保存」动作一致（ImageExporter），
    /// 放在每卡独立的子目录里避免同秒截图重名；旧文件下次启动统一清理。
    private func makeDragFile() -> URL? {
        if let dragFileURL { return dragFileURL }

        let dir = ShelfController.dragFileDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            guard let fullImage = fullImageProvider(),
                  let data = ImageCodec.pngData(from: fullImage) else { return nil }
            let url = dir.appendingPathComponent(ImageExporter.suggestedName(for: shot))
            try data.write(to: url)
            dragFileURL = url
            return url
        } catch {
            NSLog("[Index] 暂存卡片写临时文件失败: \(error)")
            return nil
        }
    }
}
