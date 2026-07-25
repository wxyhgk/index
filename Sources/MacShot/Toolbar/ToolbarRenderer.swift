import AppKit

/// 工具条的绘制。无状态 —— 截图覆盖层和钉图窗口共用。
enum ToolbarRenderer {

    @MainActor
    static func draw(
        _ slots: [ToolbarSlot],
        hovered: ToolbarItem?,
        annotation: AnnotationState
    ) {
        guard !slots.isEmpty else { return }

        for row in ToolbarLayout.rowFrames(of: slots) {
            NSColor(calibratedWhite: 0.13, alpha: 0.96).setFill()
            let path = NSBezierPath(roundedRect: row, xRadius: 8, yRadius: 8)
            path.fill()
            NSColor.white.withAlphaComponent(0.14).setStroke()
            path.lineWidth = 1
            path.stroke()
        }

        for slot in slots {
            let isSelected = isSelected(slot.item, annotation: annotation)
            let isHovered = hovered == slot.item

            if isSelected || isHovered {
                let alpha: CGFloat = isSelected ? 0.9 : 0.5
                NSColor.controlAccentColor.withAlphaComponent(alpha).setFill()
                NSBezierPath(
                    roundedRect: slot.frame.insetBy(dx: 2.5, dy: 3.5),
                    xRadius: 5, yRadius: 5
                ).fill()
            }

            draw(slot, annotation: annotation)
        }
    }

    @MainActor
    private static func isSelected(_ item: ToolbarItem, annotation: AnnotationState) -> Bool {
        switch item {
        case .tool(let tool): return annotation.tool == tool
        case .color(let index): return annotation.colorIndex == index
        case .width(let index): return annotation.widthIndex == index
        case .undo, .separator, .action: return false
        }
    }

    @MainActor
    private static func draw(_ slot: ToolbarSlot, annotation: AnnotationState) {
        let frame = slot.frame

        switch slot.item {
        case .separator:
            NSColor.white.withAlphaComponent(0.18).setFill()
            NSRect(x: frame.midX - 0.5, y: frame.minY + 9, width: 1, height: frame.height - 18).fill()

        case .tool(let tool):
            let symbol = tool?.symbolName ?? "cursorarrow"
            drawCenteredSymbol(symbol, in: frame, pointSize: 14)

        case .undo:
            drawCenteredSymbol("arrow.uturn.backward", in: frame, pointSize: 13)

        case .color(let index):
            let color = AnnotationState.palette[index]
            NSColor(srgbRed: color.r, green: color.g, blue: color.b, alpha: 1).setFill()
            let dot = NSRect(x: frame.midX - 6, y: frame.midY - 6, width: 12, height: 12)
            NSBezierPath(ovalIn: dot).fill()
            NSColor.black.withAlphaComponent(0.35).setStroke()
            let ring = NSBezierPath(ovalIn: dot)
            ring.lineWidth = 1
            ring.stroke()

        case .width(let index):
            let radius = CGFloat(AnnotationState.widths[index]) / 2 + 1.5
            NSColor.white.setFill()
            NSBezierPath(ovalIn: NSRect(
                x: frame.midX - radius,
                y: frame.midY - radius,
                width: radius * 2,
                height: radius * 2
            )).fill()

        case .action(let action):
            drawSymbol(
                action.symbolName,
                at: CGPoint(x: frame.minX + ToolbarLayout.horizontalPadding, y: frame.midY),
                pointSize: ToolbarLayout.iconSize
            )
            let attrs: [NSAttributedString.Key: Any] = [
                .font: ToolbarLayout.labelFont,
                .foregroundColor: NSColor.white
            ]
            let title = action.title as NSString
            let size = title.size(withAttributes: attrs)
            title.draw(
                at: NSPoint(
                    x: frame.minX + ToolbarLayout.horizontalPadding
                        + ToolbarLayout.iconSize + ToolbarLayout.iconGap,
                    y: frame.midY - size.height / 2
                ),
                withAttributes: attrs
            )
        }
    }

    private static func drawCenteredSymbol(_ name: String, in frame: CGRect, pointSize: CGFloat) {
        guard let icon = symbolImage(name, pointSize: pointSize, tint: .white) else { return }
        icon.draw(in: CGRect(
            x: frame.midX - icon.size.width / 2,
            y: frame.midY - icon.size.height / 2,
            width: icon.size.width,
            height: icon.size.height
        ))
    }

    private static func drawSymbol(_ name: String, at leftCenter: CGPoint, pointSize: CGFloat) {
        guard let icon = symbolImage(name, pointSize: pointSize, tint: .white) else { return }
        icon.draw(in: CGRect(
            x: leftCenter.x,
            y: leftCenter.y - icon.size.height / 2,
            width: icon.size.width,
            height: icon.size.height
        ))
    }

    private static func symbolImage(_ name: String, pointSize: CGFloat, tint: NSColor) -> NSImage? {
        guard
            let base = NSImage(systemSymbolName: name, accessibilityDescription: nil),
            let sized = base.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
            )
        else { return nil }

        let image = NSImage(size: sized.size)
        image.lockFocus()
        sized.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
        tint.set()
        NSRect(origin: .zero, size: sized.size).fill(using: .sourceAtop)
        image.unlockFocus()
        return image
    }
}
