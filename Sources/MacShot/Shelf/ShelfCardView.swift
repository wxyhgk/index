import AppKit

/// 卡片内容视图：圆角缩略图 + 底部信息条 + 悬停出现的关闭按钮。
/// 文件拖拽（NSDraggingSession）从这里发起，卡片本身不可拖动窗口。
final class ShelfCardView: NSView, NSDraggingSource {

    static let barHeight: CGFloat = 26
    private static let cornerRadius: CGFloat = DS.radiusCard
    /// 位移超过这个距离才算拖拽，避免手抖把点击吃掉。
    private static let dragThreshold: CGFloat = 4

    var onClose: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    var onHoverChanged: ((Bool) -> Void)?
    var onDragStateChanged: ((Bool) -> Void)?
    /// 拖拽发起时向控制器要临时文件；返回 nil 表示写盘失败，本次不拖。
    var makeDragFile: (() -> URL?)?
    /// 拖出成功（接收方收下了文件）。
    var onDragCompleted: (() -> Void)?

    private let image: CGImage
    private let caption: String
    private let closeButton = NSButton()
    private var mouseDownEvent: NSEvent?

    init(image: CGImage, caption: String) {
        self.image = image
        self.caption = caption
        super.init(frame: .zero)
        wantsLayer = true
        setupCloseButton()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - 布局

    /// 缩略图占据的区域：信息条以上的全部。
    private var thumbnailRect: CGRect {
        CGRect(
            x: 0,
            y: Self.barHeight,
            width: bounds.width,
            height: max(0, bounds.height - Self.barHeight)
        )
    }

    private func setupCloseButton() {
        closeButton.image = NSImage(
            systemSymbolName: "xmark.circle.fill",
            accessibilityDescription: "关闭"
        )?.withSymbolConfiguration(.init(pointSize: 15, weight: .semibold))
        closeButton.isBordered = false
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        closeButton.isHidden = true
        // 钉在卡片右上角，窗口尺寸固定所以只摆一次。
        closeButton.autoresizingMask = [.minXMargin, .minYMargin]
        addSubview(closeButton)
    }

    override func layout() {
        super.layout()
        closeButton.frame = CGRect(x: bounds.maxX - 26, y: bounds.maxY - 26, width: 20, height: 20)
    }

    @objc private func closeTapped() {
        onClose?()
    }

    // MARK: - AppKit 基础

    /// 面板永远不是 key，第一次点击也要响应。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// 卡片不许拖着走 —— mouseDragged 要留给文件拖拽。
    override var mouseDownCanMoveWindow: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        closeButton.isHidden = false
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        closeButton.isHidden = true
        onHoverChanged?(false)
    }

    // MARK: - 点击与拖拽

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            mouseDownEvent = nil
            onDoubleClick?()
            return
        }
        mouseDownEvent = event
    }

    override func mouseDragged(with event: NSEvent) {
        guard let downEvent = mouseDownEvent else { return }
        let start = convert(downEvent.locationInWindow, from: nil)
        let current = convert(event.locationInWindow, from: nil)
        guard hypot(current.x - start.x, current.y - start.y) > Self.dragThreshold else { return }

        mouseDownEvent = nil
        beginFileDrag(with: downEvent)
    }

    override func mouseUp(with event: NSEvent) {
        mouseDownEvent = nil
    }

    /// 拖出 = 文件。写临时 PNG，塞 fileURL 进拖拽粘贴板 ——
    /// Slack、微信、邮件、访达都认，等价于拖一个真实文件。
    private func beginFileDrag(with event: NSEvent) {
        guard let url = makeDragFile?() else { return }

        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        let frame = thumbnailRect
        item.setDraggingFrame(
            frame,
            contents: NSImage(cgImage: image, size: frame.size)
        )

        onDragStateChanged?(true)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    // MARK: - NSDraggingSource

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .copy
    }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        onDragStateChanged?(false)
        // 空集 = 拖到了不收文件的地方（或按 ⎋ 取消），卡片留着再试。
        if operation != [] {
            onDragCompleted?()
        }
    }

    // MARK: - 绘制

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        let card = NSBezierPath(
            roundedRect: bounds,
            xRadius: Self.cornerRadius,
            yRadius: Self.cornerRadius
        )
        NSColor.windowBackgroundColor.setFill()
        card.fill()

        // 缩略图：等比铺满上部区域，溢出裁掉，圆角跟着卡片走。
        let area = thumbnailRect
        if area.height > 1 {
            ctx.saveGState()
            card.addClip()
            ctx.clip(to: area)
            let imgW = CGFloat(max(image.width, 1))
            let imgH = CGFloat(max(image.height, 1))
            let scale = max(area.width / imgW, area.height / imgH)
            let drawSize = CGSize(width: imgW * scale, height: imgH * scale)
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(
                x: area.midX - drawSize.width / 2,
                y: area.midY - drawSize.height / 2,
                width: drawSize.width,
                height: drawSize.height
            ))
            ctx.restoreGState()
        }

        // 底部信息条：App 名 + 时间。
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let text = NSAttributedString(string: caption, attributes: [
            .font: NSFont.systemFont(ofSize: DS.font11),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph
        ])
        let textHeight = text.size().height
        text.draw(in: CGRect(
            x: 10,
            y: (Self.barHeight - textHeight) / 2,
            width: bounds.width - 20,
            height: textHeight
        ))

        // 和钉图一致的细描边，把卡片从背景里提出来。
        NSColor.white.withAlphaComponent(0.25).setStroke()
        card.lineWidth = DS.hairline
        card.stroke()
    }
}
