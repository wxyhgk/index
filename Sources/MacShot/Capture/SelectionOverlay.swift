import AppKit

/// 选区确认后可以执行的操作。
enum CaptureAction: CaseIterable {
    case pin
    case annotate
    case copy
    case save

    var symbolName: String {
        switch self {
        case .pin: return "pin.fill"
        case .annotate: return "pencil.tip.crop.circle"
        case .copy: return "doc.on.doc"
        case .save: return "square.and.arrow.down"
        }
    }

    var title: String {
        switch self {
        case .pin: return "钉图"
        case .annotate: return "标注"
        case .copy: return "复制"
        case .save: return "保存"
        }
    }
}

struct SelectionResult {
    /// AppKit 全局坐标。
    let region: CGRect
    let screen: NSScreen
    /// 单击窗口时非空 —— 走整窗捕获，能避开前面遮挡的窗口。
    let window: WindowInfo?
    let action: CaptureAction
}

/// 覆盖所有显示器的全屏选区层。
@MainActor
final class SelectionOverlayController {

    private var windows: [OverlayWindow] = []
    private var views: [OverlayView] = []
    private var completion: ((SelectionResult?) -> Void)?

    var isActive: Bool { !windows.isEmpty }

    func begin(completion: @escaping (SelectionResult?) -> Void) {
        guard !isActive else { return }
        self.completion = completion

        // 覆盖层出现前先把窗口列表快照下来，之后 hover 高亮不再反复查询系统。
        let candidates = WindowLister.onScreenWindows(
            excludingPID: ProcessInfo.processInfo.processIdentifier
        )

        for screen in NSScreen.screens {
            let window = OverlayWindow(screen: screen)
            let view = OverlayView(screen: screen, windows: candidates)
            view.onFinish = { [weak self] result in
                self?.finish(result)
            }
            view.onSelectionConfirmed = { [weak self] owner in
                // 某块屏确认了选区，其它屏只保留压暗，不再显示提示文字和窗口高亮。
                self?.views.forEach { $0.setInactive($0 !== owner) }
            }
            window.contentView = view
            window.makeKeyAndOrderFront(nil)
            windows.append(window)
            views.append(view)
        }

        NSApp.activate(ignoringOtherApps: true)
        NSCursor.crosshair.push()
    }

    private func finish(_ result: SelectionResult?) {
        let handler = completion
        completion = nil
        dismiss()
        handler?(result)
    }

    func dismiss() {
        guard isActive else { return }
        NSCursor.pop()
        NSCursor.arrow.set()
        for window in windows {
            window.orderOut(nil)
        }
        windows.removeAll()
        views.removeAll()
    }
}

// MARK: - 窗口

private final class OverlayWindow: NSWindow {

    init(screen: NSScreen) {
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .screenSaver
        ignoresMouseEvents = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        setFrame(screen.frame, display: true)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - 视图

private final class OverlayView: NSView {

    var onFinish: ((SelectionResult?) -> Void)?
    var onSelectionConfirmed: ((OverlayView) -> Void)?

    private enum Phase {
        case idle          // 等待拖拽 / 悬停窗口
        case dragging
        case confirmed     // 选区已定，工具条可点
    }

    private let screenRef: NSScreen
    private let candidates: [WindowInfo]

    private var phase: Phase = .idle
    private var dragOrigin: CGPoint?
    private var dragCurrent: CGPoint?
    private var hoveredWindow: WindowInfo?

    /// 已确认的选区（AppKit 全局坐标）及其来源窗口。
    private var confirmedRect: CGRect?
    private var confirmedWindow: WindowInfo?

    /// 别的屏已经确认了选区，这块屏只压暗。
    private var isInactive = false

    private var buttonFrames: [(rect: CGRect, action: CaptureAction)] = []
    private var hoveredAction: CaptureAction?

    /// 拖拽小于这个距离视为「点击」，走整窗选择。
    private let dragThreshold: CGFloat = 6

    private let barHeight: CGFloat = 34
    private let barGap: CGFloat = 8

    init(screen: NSScreen, windows: [WindowInfo]) {
        self.screenRef = screen
        self.candidates = windows
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.activeAlways, .mouseMoved, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
        updateHover(at: NSEvent.mouseLocation)
    }

    func setInactive(_ value: Bool) {
        guard isInactive != value else { return }
        isInactive = value
        if value {
            hoveredWindow = nil
            confirmedRect = nil
            confirmedWindow = nil
            phase = .idle
        }
        needsDisplay = true
    }

    // MARK: 坐标：视图局部 ↔ AppKit 全局

    private func toGlobal(_ local: CGPoint) -> CGPoint {
        CGPoint(x: local.x + screenRef.frame.origin.x, y: local.y + screenRef.frame.origin.y)
    }

    private func toLocal(_ global: CGPoint) -> CGPoint {
        CGPoint(x: global.x - screenRef.frame.origin.x, y: global.y - screenRef.frame.origin.y)
    }

    private func toLocal(_ global: CGRect) -> CGRect {
        CGRect(origin: toLocal(global.origin), size: global.size)
    }

    private var draggingRect: CGRect? {
        guard let a = dragOrigin, let b = dragCurrent else { return nil }
        let rect = CGRect(
            x: min(a.x, b.x),
            y: min(a.y, b.y),
            width: abs(b.x - a.x),
            height: abs(b.y - a.y)
        )
        return rect.intersection(screenRef.frame)
    }

    /// 当前应该高亮的矩形（全局坐标）。
    private var activeRect: CGRect? {
        if let confirmedRect { return confirmedRect }
        if let draggingRect { return draggingRect }
        guard !isInactive, phase == .idle else { return nil }
        return hoveredWindow?.frame.intersection(screenRef.frame)
    }

    // MARK: 事件

    override func mouseMoved(with event: NSEvent) {
        let global = NSEvent.mouseLocation
        switch phase {
        case .confirmed:
            let local = convert(event.locationInWindow, from: nil)
            let hit = buttonFrames.first { $0.rect.contains(local) }?.action
            if hit != hoveredAction {
                hoveredAction = hit
                needsDisplay = true
            }
            (hit == nil ? NSCursor.crosshair : NSCursor.arrow).set()
        case .idle:
            NSCursor.crosshair.set()
            updateHover(at: global)
        case .dragging:
            break
        }
    }

    private func updateHover(at global: CGPoint) {
        guard !isInactive else { return }
        let hit = candidates.first { $0.frame.contains(global) }
        if hit?.windowID != hoveredWindow?.windowID {
            hoveredWindow = hit
            needsDisplay = true
        }
    }

    override func mouseDown(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)

        // 工具条命中优先
        if phase == .confirmed, let hit = buttonFrames.first(where: { $0.rect.contains(local) }) {
            emit(hit.action)
            return
        }

        // 其余情况一律开始新的选区
        confirmedRect = nil
        confirmedWindow = nil
        hoveredAction = nil
        onSelectionConfirmed?(self)   // 让其它屏恢复
        dragOrigin = toGlobal(local)
        dragCurrent = dragOrigin
        phase = .dragging
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard phase == .dragging else { return }
        dragCurrent = toGlobal(convert(event.locationInWindow, from: nil))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard phase == .dragging, let origin = dragOrigin, let current = dragCurrent else { return }

        let travelled = hypot(current.x - origin.x, current.y - origin.y)
        if travelled < dragThreshold {
            // 点击 → 选中整个窗口
            if let window = candidates.first(where: { $0.frame.contains(current) }) {
                confirmedRect = window.frame.intersection(screenRef.frame)
                confirmedWindow = window
            } else {
                dragOrigin = nil
                dragCurrent = nil
                phase = .idle
                needsDisplay = true
                return
            }
        } else if let rect = draggingRect, rect.width >= 2, rect.height >= 2 {
            confirmedRect = rect
            confirmedWindow = nil
        } else {
            dragOrigin = nil
            dragCurrent = nil
            phase = .idle
            needsDisplay = true
            return
        }

        dragOrigin = nil
        dragCurrent = nil
        phase = .confirmed
        hoveredAction = nil
        onSelectionConfirmed?(self)
        NSCursor.arrow.set()
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        let cmd = event.modifierFlags.contains(.command)
        switch event.keyCode {
        case 53:                       // ESC
            onFinish?(nil)
        case 36, 76 where phase == .confirmed:   // Return / Enter
            emit(.pin)
        case 8 where cmd:              // ⌘C
            emit(.copy)
        case 1 where cmd:              // ⌘S
            emit(.save)
        case 14:                       // E
            emit(.annotate)
        default:
            super.keyDown(with: event)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        if phase == .confirmed {
            confirmedRect = nil
            confirmedWindow = nil
            phase = .idle
            needsDisplay = true
        } else {
            onFinish?(nil)
        }
    }

    private func emit(_ action: CaptureAction) {
        guard phase == .confirmed, let rect = confirmedRect else { return }
        onFinish?(SelectionResult(
            region: rect,
            screen: screenRef,
            window: confirmedWindow,
            action: action
        ))
    }

    // MARK: 绘制

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        ctx.setFillColor(NSColor.black.withAlphaComponent(0.35).cgColor)
        ctx.fill(bounds)

        guard let globalRect = activeRect, !globalRect.isEmpty else {
            buttonFrames = []
            drawHint(in: ctx)
            return
        }

        let local = toLocal(globalRect)

        // 挖空选区
        ctx.setBlendMode(.clear)
        ctx.fill(local)
        ctx.setBlendMode(.normal)

        let isWindowHint = (phase == .idle && confirmedRect == nil)
        ctx.setStrokeColor((isWindowHint ? NSColor.systemBlue : NSColor.white).cgColor)
        ctx.setLineWidth(isWindowHint ? 3 : 1.5)
        ctx.stroke(local.insetBy(dx: -0.75, dy: -0.75))

        drawSizeLabel(for: globalRect, near: local, isWindow: isWindowHint, in: ctx)

        if phase == .confirmed {
            drawToolbar(for: local, in: ctx)
        } else {
            buttonFrames = []
        }
    }

    private func drawHint(in ctx: CGContext) {
        guard !isInactive, screenRef == NSScreen.main else { return }
        let text = "拖拽选区 · 单击窗口 · ESC 取消"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.85)
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        (text as NSString).draw(
            at: NSPoint(x: (bounds.width - size.width) / 2, y: bounds.height * 0.62),
            withAttributes: attrs
        )
    }

    private func drawSizeLabel(for globalRect: CGRect, near local: CGRect, isWindow: Bool, in ctx: CGContext) {
        let scale = screenRef.backingScaleFactor
        var text = "\(Int(globalRect.width * scale)) × \(Int(globalRect.height * scale))"
        if isWindow, let name = hoveredWindow?.ownerName {
            text = "\(name)  \(text)"
        }

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let textSize = (text as NSString).size(withAttributes: attrs)
        let padding: CGFloat = 6
        var box = NSRect(
            x: local.minX,
            y: local.maxY + 6,
            width: textSize.width + padding * 2,
            height: textSize.height + padding
        )
        if box.maxY > bounds.maxY { box.origin.y = local.minY - box.height - 6 }
        if box.maxX > bounds.maxX { box.origin.x = bounds.maxX - box.width - 4 }
        box.origin.x = max(4, box.origin.x)

        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5).fill()
        (text as NSString).draw(
            at: NSPoint(x: box.minX + padding, y: box.minY + padding / 2),
            withAttributes: attrs
        )
    }

    // MARK: 工具条

    private func drawToolbar(for selection: CGRect, in ctx: CGContext) {
        let labelFont = NSFont.systemFont(ofSize: 12, weight: .medium)
        let hPadding: CGFloat = 11
        let iconSize: CGFloat = 15
        let iconGap: CGFloat = 5

        // 先量宽度
        var widths: [CGFloat] = []
        for action in CaptureAction.allCases {
            let textWidth = (action.title as NSString)
                .size(withAttributes: [.font: labelFont]).width
            widths.append(hPadding * 2 + iconSize + iconGap + textWidth)
        }
        let barWidth = widths.reduce(0, +)

        // 定位：优先贴在选区下方右对齐，放不下就翻到上方，再放不下就压在选区内部
        var barX = selection.maxX - barWidth
        var barY = selection.minY - barGap - barHeight
        if barY < 4 {
            barY = selection.maxY + barGap
        }
        if barY + barHeight > bounds.maxY - 4 {
            barY = max(4, selection.minY + barGap)
        }
        barX = min(max(4, barX), bounds.maxX - barWidth - 4)

        let barRect = CGRect(x: barX, y: barY, width: barWidth, height: barHeight)

        // 背景
        NSColor(calibratedWhite: 0.13, alpha: 0.96).setFill()
        let path = NSBezierPath(roundedRect: barRect, xRadius: 8, yRadius: 8)
        path.fill()
        NSColor.white.withAlphaComponent(0.14).setStroke()
        path.lineWidth = 1
        path.stroke()

        // 逐个按钮
        buttonFrames = []
        var cursorX = barRect.minX
        for (index, action) in CaptureAction.allCases.enumerated() {
            let width = widths[index]
            let frame = CGRect(x: cursorX, y: barRect.minY, width: width, height: barHeight)
            buttonFrames.append((frame, action))

            let isHovered = hoveredAction == action
            if isHovered {
                NSColor.controlAccentColor.withAlphaComponent(0.85).setFill()
                NSBezierPath(
                    roundedRect: frame.insetBy(dx: 2.5, dy: 3.5),
                    xRadius: 5, yRadius: 5
                ).fill()
            }

            let tint = NSColor.white
            if let icon = symbolImage(action.symbolName, pointSize: iconSize, tint: tint) {
                icon.draw(in: CGRect(
                    x: frame.minX + hPadding,
                    y: frame.midY - icon.size.height / 2,
                    width: icon.size.width,
                    height: icon.size.height
                ))
            }

            let attrs: [NSAttributedString.Key: Any] = [
                .font: labelFont,
                .foregroundColor: tint
            ]
            let textSize = (action.title as NSString).size(withAttributes: attrs)
            (action.title as NSString).draw(
                at: NSPoint(
                    x: frame.minX + hPadding + iconSize + iconGap,
                    y: frame.midY - textSize.height / 2
                ),
                withAttributes: attrs
            )

            cursorX += width
        }
    }

    private func symbolImage(_ name: String, pointSize: CGFloat, tint: NSColor) -> NSImage? {
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil) else {
            return nil
        }
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
        guard let sized = base.withSymbolConfiguration(config) else { return nil }

        let image = NSImage(size: sized.size)
        image.lockFocus()
        sized.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
        tint.set()
        NSRect(origin: .zero, size: sized.size).fill(using: .sourceAtop)
        image.unlockFocus()
        return image
    }
}
