import AppKit

/// 钉图的内容视图。
///
/// 和截图覆盖层共用 `AnnotationState` / `ToolbarLayout` / `ToolbarRenderer` ——
/// 所以钉完图之后工具条不换、手感不断，可以接着画。
///
/// 画布空间是**图片像素、左上原点**，标注图层直接存在这个坐标系里，
/// 和入库的修订一致，不需要再做换算。
final class PinImageView: NSView {

    var onScrollZoom: ((CGFloat) -> Void)?
    var onOpacityStep: ((CGFloat) -> Void)?
    var onAction: ((String) -> Void)?
    var onAnnotationsChanged: (() -> Void)?
    /// 工具条行数变化时通知控制器调整窗口高度。
    var onToolbarHeightChanged: (() -> Void)?

    let annotation = AnnotationState()

    private let base: CGImage
    /// 截图时画的标注，只读地叠在底图上。
    private let initialLayers: [Layer]
    /// 底图 + 已应用的马赛克。只在马赛克图层增减时重算，绝不逐帧跑 CoreImage。
    private var canvasImage: CGImage

    private var isHovering = false
    private var hoveredItem: ToolbarItem?

    init(base: CGImage, layers: [Layer]) {
        self.base = base
        self.initialLayers = layers
        let pixelates = layers.filter { $0.kind == .pixelate }
        self.canvasImage = pixelates.isEmpty
            ? base
            : LayerRenderer.render(base: base, layers: pixelates)

        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    /// 截图时的标注 + 钉图后新加的，合起来就是当前这版的完整图层。
    var allLayers: [Layer] { initialLayers + annotation.layers }

    // MARK: - 布局

    /// 窗口底部留给工具条的空白条带。它是透明的 —— 看上去就是工具条浮在图片下方，
    /// 和截图时工具条贴在选区外侧的位置关系完全一致。
    var requiredStripHeight: CGFloat {
        ToolbarLayout.blockHeight(in: bounds.width, config: toolbarConfig(anchor: .zero))
            + ToolbarLayout.gap + 4
    }

    /// 图片实际占据的区域：视图顶部，底下让出条带。
    private var imageRect: CGRect {
        let strip = requiredStripHeight
        return CGRect(
            x: 0,
            y: strip,
            width: bounds.width,
            height: max(0, bounds.height - strip)
        )
    }

    // MARK: - 画布换算

    /// 图片像素 → 视图点。
    private var displayScale: CGFloat {
        guard base.width > 0, imageRect.width > 0 else { return 1 }
        return imageRect.width / CGFloat(base.width)
    }

    private func canvasPoint(_ viewLocal: CGPoint) -> CGPoint {
        let inverse = 1 / max(displayScale, 0.0001)
        return CGPoint(
            x: (viewLocal.x - imageRect.minX) * inverse,
            y: (imageRect.maxY - viewLocal.y) * inverse
        )
    }

    private func syncStrokeScale() {
        // 笔宽按显示倍率反算，这样不论钉图被缩放到多大，画出来的线在屏幕上都一样粗。
        annotation.strokeScale = Double(1 / max(displayScale, 0.0001))
    }

    // MARK: - 工具条

    private func toolbarConfig(anchor: CGRect) -> ToolbarLayout.Configuration {
        .init(
            anchor: anchor,
            alignment: .center,
            actions: CaptureActionRegistry.shared.descriptors(in: .pinned),
            tool: annotation.tool,
            hasAnnotations: !annotation.isEmpty,
            placement: .below
        )
    }

    private var slots: [ToolbarSlot] {
        ToolbarLayout.slots(in: bounds, config: toolbarConfig(anchor: imageRect))
    }

    private var toolbarAlpha: CGFloat { isHovering ? 1.0 : 0.45 }

    private func handleToolbar(_ item: ToolbarItem) {
        let heightBefore = requiredStripHeight
        defer {
            if requiredStripHeight != heightBefore { onToolbarHeightChanged?() }
        }

        switch item {
        case .tool(let tool):
            annotation.endTextEditing()
            annotation.tool = tool
        case .color(let index):
            annotation.colorIndex = index
        case .width(let index):
            annotation.widthIndex = index
        case .undo:
            annotation.undo()
            refreshCanvas()
            onAnnotationsChanged?()
        case .action(let descriptor):
            onAction?(descriptor.id)
            return
        case .separator:
            return
        }
        needsDisplay = true
    }

    private func refreshCanvas() {
        let pixelates = allLayers.filter { $0.kind == .pixelate }
        canvasImage = pixelates.isEmpty
            ? base
            : LayerRenderer.render(base: base, layers: pixelates)
    }

    // MARK: - AppKit 基础

    override var acceptsFirstResponder: Bool { true }

    /// 钉图窗口经常不是 key，没有这个的话第一次点击会被吞掉。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// 自己接管拖动，AppKit 不要插手 —— 否则点工具条会被当成拖窗口。
    override var mouseDownCanMoveWindow: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved],
            owner: self,
            userInfo: nil
        ))
    }

    // MARK: - 鼠标

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        hoveredItem = nil
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let hit = slots.first { $0.item.isInteractive && $0.frame.contains(point) }?.item
        if hit != hoveredItem {
            hoveredItem = hit
            needsDisplay = true
        }
        (hit == nil && annotation.tool != nil ? NSCursor.crosshair : NSCursor.arrow).set()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        if let slot = slots.first(where: { $0.item.isInteractive && $0.frame.contains(point) }) {
            handleToolbar(slot.item)
            return
        }

        if annotation.tool != nil, imageRect.contains(point) {
            syncStrokeScale()
            annotation.beginDraw(at: canvasPoint(point))
            needsDisplay = true
            return
        }

        annotation.endTextEditing()

        if event.clickCount == 2 {
            onAction?(ActionID.copy)
            return
        }

        window?.performDrag(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard annotation.isDrawing else { return }
        let point = convert(event.locationInWindow, from: nil)
        if annotation.updateDraw(to: canvasPoint(point)) {
            needsDisplay = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard annotation.isDrawing else { return }
        annotation.endDraw { [base] rect in
            base.cropping(to: rect.integral)
        }
        refreshCanvas()
        needsDisplay = true
        onAnnotationsChanged?()
    }

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            onOpacityStep?(event.scrollingDeltaY > 0 ? 0.05 : -0.05)
        } else {
            onScrollZoom?(event.scrollingDeltaY)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        if annotation.isEditingText {
            annotation.endTextEditing()
            needsDisplay = true
        } else if annotation.tool != nil {
            annotation.tool = nil
            needsDisplay = true
        } else {
            super.rightMouseDown(with: event)
        }
    }

    // MARK: - 绘制

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let frame = imageRect
        guard frame.height > 1 else { return }

        let clip = NSBezierPath(roundedRect: frame, xRadius: 6, yRadius: 6)
        ctx.saveGState()
        clip.addClip()
        ctx.interpolationQuality = .high
        ctx.draw(canvasImage, in: frame)
        drawAnnotations(in: ctx)
        ctx.restoreGState()

        NSColor.white.withAlphaComponent(0.25).setStroke()
        clip.lineWidth = 1
        clip.stroke()

        ctx.saveGState()
        ctx.setAlpha(toolbarAlpha)
        ToolbarRenderer.draw(slots, hovered: hoveredItem, annotation: annotation)
        ctx.restoreGState()
    }

    private func drawAnnotations(in ctx: CGContext) {
        let layers = initialLayers + annotation.displayLayers
        guard !layers.isEmpty else { return }

        let scale = displayScale
        ctx.saveGState()
        // 翻成「图片像素、左上原点、Y 向下」—— 和图层坐标系一致。
        ctx.translateBy(x: imageRect.minX, y: imageRect.maxY)
        ctx.scaleBy(x: scale, y: -scale)
        AnnotationRenderer.draw(
            layers,
            pixelatePreviews: annotation.pixelatePreviews,
            in: ctx
        )
        ctx.restoreGState()
    }
}
