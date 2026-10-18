import AppKit

/// 工具条绘制。底板和选中/悬停高亮在这里统一画，控件内容交给控件自己。
@MainActor
enum ToolbarRenderer {

    static func draw(
        _ slots: [ToolbarSlot],
        hovered: String?,
        pressed: String? = nil,
        focused: String? = nil,
        context: ToolbarContext
    ) {
        guard !slots.isEmpty else { return }

        // 每行独立宽度底板，左边缘对齐。第一栏不随第二栏拉宽。
        let rows = ToolbarLayout.rowFrames(of: slots)
        let leftEdge = rows.map { $0.minX }.min() ?? 0
        for row in rows {
            let bg = CGRect(x: leftEdge, y: row.minY, width: row.width, height: row.height)
            DS.toolbarBackground.setFill()
            let path = NSBezierPath(roundedRect: bg, xRadius: DS.radiusMedium, yRadius: DS.radiusMedium)
            path.fill()
            DS.toolbarStroke.setStroke()
            path.lineWidth = DS.hairline
            path.stroke()
        }

        for slot in slots {
            guard let control = slot.control else {
                drawSeparator(in: slot.frame)
                continue
            }

            let state = ToolbarRenderState(
                isSelected: control.isSelected(context),
                isHovered: hovered == control.id,
                isFocused: focused == control.id,
                // 按住后拖出按钮应取消按压视觉；拖回同一按钮则恢复。
                isPressed: pressed == control.id && hovered == control.id,
                isEnabled: control.isEnabled(context),
                isBusy: control.isBusy(context)
            )

            if state.isEnabled && (state.isSelected || state.isHovered || state.isFocused || state.isPressed) {
                (state.isSelected || state.isPressed ? DS.toolbarSelected : DS.toolbarHover)
                    .setFill()
                NSBezierPath(
                    roundedRect: slot.frame.insetBy(dx: 2.5, dy: 3.5),
                    xRadius: 5, yRadius: 5
                ).fill()
            }

            if state.isEnabled && state.isFocused {
                NSColor.keyboardFocusIndicatorColor.setStroke()
                let focus = NSBezierPath(
                    roundedRect: slot.frame.insetBy(dx: 2, dy: 3),
                    xRadius: 5,
                    yRadius: 5
                )
                focus.lineWidth = DS.strokeEmphasis
                focus.stroke()
            }

            NSGraphicsContext.saveGraphicsState()
            if !state.isEnabled {
                NSGraphicsContext.current?.cgContext.setAlpha(state.isBusy ? 0.72 : 0.32)
            }
            control.draw(in: slot.frame, context: context, state: state)
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    private static func drawSeparator(in frame: CGRect) {
        DS.toolbarSeparator.setFill()
        NSRect(x: frame.midX - 0.5, y: frame.minY + 9, width: 1, height: frame.height - 18).fill()
    }
}
