import AppKit

/// 工具条绘制。底板和选中/悬停高亮在这里统一画，控件内容交给控件自己。
@MainActor
enum ToolbarRenderer {

    static func draw(_ slots: [ToolbarSlot], hovered: String?, context: ToolbarContext) {
        guard !slots.isEmpty else { return }

        // 两行各自圆角底板（PixPin 双胶囊），行间留 `interRowGap` 缝。
        for row in ToolbarLayout.rowFrames(of: slots) {
            let bg = row
            DS.toolbarBackground.setFill()
            let path = NSBezierPath(roundedRect: bg, xRadius: 8, yRadius: 8)
            path.fill()
            DS.toolbarStroke.setStroke()
            path.lineWidth = 1
            path.stroke()
        }

        for slot in slots {
            guard let control = slot.control else {
                drawSeparator(in: slot.frame)
                continue
            }

            let state = ToolbarRenderState(
                isSelected: control.isSelected(context),
                isHovered: hovered == control.id
            )

            if state.isSelected || state.isHovered {
                (state.isSelected ? DS.toolbarSelected : DS.toolbarHover)
                    .setFill()
                NSBezierPath(
                    roundedRect: slot.frame.insetBy(dx: 2.5, dy: 3.5),
                    xRadius: 5, yRadius: 5
                ).fill()
            }

            control.draw(in: slot.frame, context: context, state: state)
        }
    }

    private static func drawSeparator(in frame: CGRect) {
        DS.toolbarSeparator.setFill()
        NSRect(x: frame.midX - 0.5, y: frame.minY + 9, width: 1, height: frame.height - 18).fill()
    }
}
