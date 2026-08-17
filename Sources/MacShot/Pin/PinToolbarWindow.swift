import AppKit

/// 钉图的工具条 —— **一个独立的子窗口**，不住在钉图窗口里面。
///
/// 之前它画在钉图窗口内部，靠从窗口高度里切走一条「条带」腾地方；而条带的高度
/// 又取决于窗口宽度（宽度不够就折行）。于是有了一个反馈回路：缩放钉图 → 条带高度变
/// → 图片显示区变 → 显示倍率变；窗口太小时工具条还会整个消失。
///
/// 拆开之后：钉图窗口只装图片，工具条按内容与屏幕上限定尺寸，两者之间只剩「贴在一起」
/// 这一条关系。钉图缩到 100×80 还是放到全屏，工具条都是同一条。
///
/// 挂法是 `addChildWindow(_:ordered: .above)`：跟着父窗口移动是 AppKit 自带的，
/// 缩放和翻转由 `PinWindowController` 在父窗口 frame 变化时调 `reposition(around:)`。
@MainActor
final class PinToolbarView: NSView {

    /// 工具条贴在钉图的哪一侧。让位的空隙永远朝着图片那一边。
    enum Attachment { case below, above }

    /// 画什么、点了谁来处理 —— 一律回到钉图视图那边。
    /// 工具条自己不持有任何状态：标注、选字、撤销栈只有一份。
    var context: (() -> ToolbarContext?)?
    var onActivate: ((any ToolbarControl) -> Void)?
    /// 鼠标进出。宿主据此把两个窗口的悬停状态合并成一个（见 `PinWindowController`）。
    var onHoverChanged: (() -> Void)?
    /// 在工具条空白处拖动 = 拖整个钉图，保住「拖条带挪窗口」的老手感。
    var onDragBy: ((CGSize) -> Void)?
    /// 滚轮在工具条上改粗细后，通知宿主重绘与重新布局。
    var onWidthStepped: (() -> Void)?

    var attachment: Attachment = .below {
        didSet { if attachment != oldValue { needsDisplay = true } }
    }
    var maximumWidth: CGFloat?

    private var hoveredControlID: String?
    private var pressedControlID: String?
    private var focusedControlID: String?
    private var widthScroll = ToolbarScrollAccumulator()
    private var toolTipTags: [NSView.ToolTipTag] = []
    private var toolTipOwners: [NSView.ToolTipTag: ToolbarToolTipOwner] = [:]
    private var toolTipSignature = ""
    /// 这一轮拖动是在挪窗口，还是按在控件上手抖。
    private var dragsWindow = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - 布局

    /// 窗口该开多大：工具条内容宽（受屏幕上限约束）×（行高 + 透明让位空隙）。
    ///
    /// 空隙也归这个窗口管，而不是留成两窗之间的真空 —— 否则鼠标从图片挪到工具条
    /// 的途中会掉出所有窗口，悬停状态跟着闪。
    var preferredSize: CGSize {
        guard let context = context?() else { return .zero }
        let block = ToolbarLayout.blockSize(context, maximumWidth: maximumWidth)
        guard block.width > 0 else { return .zero }
        return CGSize(width: block.width, height: block.height + ToolbarLayout.gap)
    }

    /// 行的左下角：让位空隙在朝着图片的那一侧。
    private var rowOrigin: CGPoint {
        CGPoint(x: 0, y: attachment == .below ? 0 : ToolbarLayout.gap)
    }

    /// 绘制和命中测试用同一份结果。
    private var slots: [ToolbarSlot] {
        guard let context = context?() else { return [] }
        return ToolbarLayout.slots(
            origin: rowOrigin,
            context: context,
            maximumWidth: maximumWidth
        )
    }

    private var enabledControlIDs: [String] {
        guard let context = context?() else { return [] }
        return slots.compactMap { slot in
            guard let control = slot.control, control.isEnabled(context) else { return nil }
            return control.id
        }
    }

    func handleKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if event.keyCode == KeyCode.tab, modifiers.subtracting(.shift).isEmpty {
            focusedControlID = ToolbarFocusNavigator.next(
                in: enabledControlIDs,
                current: focusedControlID,
                offset: modifiers.contains(.shift) ? -1 : 1
            )
            needsDisplay = true
            return true
        }
        guard focusedControlID != nil else { return false }
        switch event.keyCode {
        case KeyCode.left:
            focusedControlID = ToolbarFocusNavigator.next(
                in: enabledControlIDs, current: focusedControlID, offset: -1
            )
        case KeyCode.right:
            focusedControlID = ToolbarFocusNavigator.next(
                in: enabledControlIDs, current: focusedControlID, offset: 1
            )
        case KeyCode.space, KeyCode.returnKey, KeyCode.keypadEnter:
            guard let context = context?(),
                  let control = slots.compactMap(\.control).first(where: {
                      $0.id == focusedControlID && $0.isEnabled(context)
                  })
            else { return true }
            onActivate?(control)
        case KeyCode.escape:
            focusedControlID = nil
        default:
            return false
        }
        needsDisplay = true
        return true
    }

    func clearKeyboardFocus() {
        guard focusedControlID != nil else { return }
        focusedControlID = nil
        needsDisplay = true
    }

    func refreshToolTips() {
        guard let context = context?() else { return }
        let entries = slots.compactMap { slot -> (CGRect, String)? in
            guard let control = slot.control else { return nil }
            return (slot.frame, control.accessibilityLabel(context))
        }
        let signature = entries.map { "\(NSStringFromRect($0.0)):\($0.1)" }.joined(separator: "|")
        guard signature != toolTipSignature else { return }
        clearToolTips()
        toolTipTags = entries.map { frame, label in
            let owner = ToolbarToolTipOwner(label)
            let tag = addToolTip(frame, owner: owner, userData: nil)
            toolTipOwners[tag] = owner
            return tag
        }
        toolTipSignature = signature
    }

    func clearToolTips() {
        toolTipTags.forEach(removeToolTip)
        toolTipTags.removeAll()
        toolTipOwners.removeAll()
        toolTipSignature = ""
    }

    // MARK: - AppKit 基础

    /// 工具条窗口永远不是 key（见 `PinToolbarPanel`），没有这个第一次点击会被吞掉。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// 自己接管拖动，AppKit 不要插手。
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
        onHoverChanged?()
    }

    override func mouseExited(with event: NSEvent) {
        if hoveredControlID != nil {
            hoveredControlID = nil
            needsDisplay = true
        }
        onHoverChanged?()
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let hit = slots.first { $0.control != nil && $0.hitFrame.contains(point) }?.control?.id
        if hit != hoveredControlID {
            hoveredControlID = hit
            needsDisplay = true
        }
        NSCursor.arrow.set()
        onHoverChanged?()
    }

    override func mouseDown(with event: NSEvent) {
        // 工具条窗口自己不能成为 key，点它得把 key 交回钉图窗口 ——
        // 否则点完一个工具，键盘就不在钉图上了（工具条还在窗口里时这是自动的）。
        window?.parent?.makeKey()

        let point = convert(event.locationInWindow, from: nil)
        let control = slots.first { $0.control != nil && $0.hitFrame.contains(point) }?.control
        // 按在控件上就是点控件，之后的拖动不算拖窗口（手滑不该把钉图挪走）。
        dragsWindow = control == nil
        if let control {
            // 禁用控件也消费完整点击，但只在 mouseUp 时判断是否执行。
            pressedControlID = control.id
            hoveredControlID = control.id
            focusedControlID = control.id
            needsDisplay = true
        } else {
            clearKeyboardFocus()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if let pressedControlID {
            let point = convert(event.locationInWindow, from: nil)
            let stillInside = slots.contains {
                $0.control?.id == pressedControlID && $0.hitFrame.contains(point)
            }
            let nextHover = stillInside ? pressedControlID : nil
            if nextHover != hoveredControlID {
                hoveredControlID = nextHover
                needsDisplay = true
            }
            return
        }
        guard dragsWindow else { return }
        onDragBy?(CGSize(width: event.deltaX, height: event.deltaY))
    }

    override func mouseUp(with event: NSEvent) {
        if let pressedID = pressedControlID {
            let point = convert(event.locationInWindow, from: nil)
            let control = slots.first {
                $0.control?.id == pressedID && $0.hitFrame.contains(point)
            }?.control
            pressedControlID = nil
            hoveredControlID = control?.id
            if let context = context?(), let control, control.isEnabled(context) {
                onActivate?(control)
            }
            needsDisplay = true
        }
        dragsWindow = false
    }

    override func scrollWheel(with event: NSEvent) {
        // 工具条上滚轮改粗细（与截图覆盖层一致，右侧调节区直连滚轮）
        if let context = context?(),
           context.annotation.styleAxes.contains(.width) {
            if !event.momentumPhase.isEmpty {
                if event.momentumPhase.contains(.ended) { widthScroll.reset() }
                return
            }
            if let step = widthScroll.step(
                delta: event.scrollingDeltaY,
                isPrecise: event.hasPreciseScrollingDeltas
            ), context.annotation.stepWidth(by: step) {
                needsDisplay = true
                onWidthStepped?()
                return
            }
        }
        widthScroll.reset()
        super.scrollWheel(with: event)
    }

    // MARK: - 绘制

    override func draw(_ dirtyRect: NSRect) {
        guard let context = context?() else { return }
        ToolbarRenderer.draw(
            slots,
            hovered: hoveredControlID,
            pressed: pressedControlID,
            focused: focusedControlID,
            context: context
        )
    }
}

/// 承载工具条的无边框面板。
@MainActor
final class PinToolbarPanel: NSPanel {

    /// 不叫 `toolbar` —— `NSWindow` 已经有一个同名的 `NSToolbar?`。
    let toolbarView = PinToolbarView(frame: .zero)

    init() {
        super.init(
            // 占位尺寸，`reposition(around:)` 会立刻按内容重开。
            contentRect: CGRect(x: 0, y: 0, width: 100, height: ToolbarLayout.rowHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        // 生命周期由 PinWindowController 持有，不能让 close 把它释放掉。
        isReleasedWhenClosed = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isMovableByWindowBackground = false
        contentView = toolbarView
    }

    /// 键盘始终留在钉图窗口：点工具条不该把焦点抢走，`PinKeyboard` 一行都不用改。
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// 按内容定尺寸，贴到钉图窗口下方居中。
    ///
    /// 屏幕下边缘放不下就翻到上方；横向过窄时布局会收起动作文字。
    /// 上下都放不下（窗口比屏幕还高）时仍保留固定行高。
    func reposition(around parent: NSWindow) {
        let anchor = parent.frame
        let limit = (parent.screen ?? NSScreen.main)?.visibleFrame ?? anchor
        toolbarView.maximumWidth = max(0, limit.width - 8)
        let size = toolbarView.preferredSize
        guard size.width > 0 else { return }

        let fitsBelow = anchor.minY - size.height >= limit.minY
        let fitsAbove = anchor.maxY + size.height <= limit.maxY
        let attachment: PinToolbarView.Attachment = (fitsBelow || !fitsAbove) ? .below : .above
        toolbarView.attachment = attachment
        toolbarView.refreshToolTips()

        let y = attachment == .below ? anchor.minY - size.height : anchor.maxY
        let leftLimit = limit.minX + 4
        let x = min(
            max(anchor.midX - size.width / 2, leftLimit),
            max(leftLimit, limit.maxX - size.width - 4)
        )

        // 宽度向上取整：控件宽度里有文字测量出来的小数，取整成窗口尺寸时
        // 少一个像素就会把最后一个按钮切掉一条边。
        let target = CGRect(
            x: x.rounded(), y: y.rounded(),
            width: size.width.rounded(.up), height: size.height
        )
        if !target.equalTo(frame) {
            setFrame(target, display: true)
            invalidateShadow()
        }
        toolbarView.needsDisplay = true
    }
}
