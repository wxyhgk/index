import AppKit

struct PinToolbarButton {
    /// 视图局部坐标。
    let frame: CGRect
    let action: PinAction
}

/// 悬停工具条的布局。纯几何 —— 绘制和命中测试用同一份结果。
enum PinToolbarLayout {

    static let buttonSize = CGSize(width: 30, height: 28)
    static let padding: CGFloat = 5
    static let bottomMargin: CGFloat = 10

    /// 比这更小的钉图，工具条会盖住图本身，索性不显示。
    static let minimumHostSize = CGSize(width: 56, height: 48)

    static func buttons(in bounds: CGRect) -> [PinToolbarButton] {
        guard bounds.width >= minimumHostSize.width,
              bounds.height >= minimumHostSize.height else { return [] }

        let actions = fittingActions(in: bounds.width)
        guard !actions.isEmpty else { return [] }

        let barWidth = CGFloat(actions.count) * buttonSize.width + padding * 2
        let originX = (bounds.width - barWidth) / 2 + padding

        return actions.enumerated().map { index, action in
            PinToolbarButton(
                frame: CGRect(
                    x: originX + CGFloat(index) * buttonSize.width,
                    y: bottomMargin + padding,
                    width: buttonSize.width,
                    height: buttonSize.height
                ),
                action: action
            )
        }
    }

    private static func fittingActions(in width: CGFloat) -> [PinAction] {
        var actions = PinAction.primary
        let available = width - 8

        func barWidth(_ count: Int) -> CGFloat {
            CGFloat(count) * buttonSize.width + padding * 2
        }

        for candidate in PinAction.droppingOrder where barWidth(actions.count) > available {
            actions.removeAll { $0 == candidate }
        }
        return actions
    }

    static func barFrame(of buttons: [PinToolbarButton]) -> CGRect? {
        guard let first = buttons.first, let last = buttons.last else { return nil }
        return first.frame.union(last.frame).insetBy(dx: -padding, dy: -padding)
    }
}

/// 悬停工具条的绘制。无状态。
enum PinToolbarRenderer {

    static func draw(_ buttons: [PinToolbarButton], hovered: PinAction?) {
        guard let barRect = PinToolbarLayout.barFrame(of: buttons) else { return }

        NSColor(calibratedWhite: 0.11, alpha: 0.92).setFill()
        let path = NSBezierPath(roundedRect: barRect, xRadius: 8, yRadius: 8)
        path.fill()
        NSColor.white.withAlphaComponent(0.16).setStroke()
        path.lineWidth = 1
        path.stroke()

        for button in buttons {
            if hovered == button.action {
                NSColor.controlAccentColor.withAlphaComponent(0.85).setFill()
                NSBezierPath(
                    roundedRect: button.frame.insetBy(dx: 2, dy: 2),
                    xRadius: 5, yRadius: 5
                ).fill()
            }
            drawSymbol(button.action.symbolName, in: button.frame)
        }
    }

    private static func drawSymbol(_ name: String, in frame: CGRect) {
        guard
            let base = NSImage(systemSymbolName: name, accessibilityDescription: nil),
            let sized = base.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
            )
        else { return }

        let tinted = NSImage(size: sized.size)
        tinted.lockFocus()
        sized.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
        NSColor.white.set()
        NSRect(origin: .zero, size: sized.size).fill(using: .sourceAtop)
        tinted.unlockFocus()

        tinted.draw(in: CGRect(
            x: frame.midX - tinted.size.width / 2,
            y: frame.midY - tinted.size.height / 2,
            width: tinted.size.width,
            height: tinted.size.height
        ))
    }
}
