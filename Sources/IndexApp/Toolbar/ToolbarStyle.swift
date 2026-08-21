import AppKit

/// 工具条的度量与绘制基元。控件和渲染器共用，保证视觉一致。
enum ToolbarStyle {

    static let rowHeight: CGFloat = 34
    static let anchorGap: CGFloat = 8
    /// 命中区比视觉区外扩的量（Fitts）：点击/悬停判定用 `ToolbarSlot.hitFrame`，
    /// 绘制仍用精确 frame。相邻控件的外扩区重叠时按 slot 顺序取先者。
    static let hitPadding: CGFloat = 4

    static let iconButtonWidth: CGFloat = 30
    /// 极窄屏仍需保留全部主动作时，只压缩 1pt 点击格并缩短组间距。
    /// 29pt 仍明显大于图标本身，命中区域高度保持 34pt 不变。
    static let compactIconButtonWidth: CGFloat = 29
    static let swatchWidth: CGFloat = 22
    static let separatorWidth: CGFloat = 9
    static let compactSeparatorWidth: CGFloat = 5

    static let horizontalPadding: CGFloat = 11
    static let iconSize: CGFloat = 15
    static let iconGap: CGFloat = 5

    static var labelFont: NSFont { .systemFont(ofSize: 12, weight: .medium) }

    static func labelWidth(_ text: String) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: labelFont]).width
    }

    // MARK: - 绘制基元

    static func drawCenteredSymbol(_ name: String, in frame: CGRect, pointSize: CGFloat = 14) {
        guard let icon = symbolImage(name, pointSize: pointSize) else { return }
        icon.draw(in: CGRect(
            x: frame.midX - icon.size.width / 2,
            y: frame.midY - icon.size.height / 2,
            width: icon.size.width,
            height: icon.size.height
        ))
    }

    static func drawIconAndLabel(_ symbolName: String, _ title: String, in frame: CGRect) {
        if let icon = symbolImage(symbolName, pointSize: iconSize) {
            icon.draw(in: CGRect(
                x: frame.minX + horizontalPadding,
                y: frame.midY - icon.size.height / 2,
                width: icon.size.width,
                height: icon.size.height
            ))
        }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: labelFont,
            .foregroundColor: NSColor.white
        ]
        let text = title as NSString
        let size = text.size(withAttributes: attrs)
        text.draw(
            at: NSPoint(
                x: frame.minX + horizontalPadding + iconSize + iconGap,
                y: frame.midY - size.height / 2
            ),
            withAttributes: attrs
        )
    }

    static func symbolImage(_ name: String, pointSize: CGFloat) -> NSImage? {
        guard
            let base = NSImage(systemSymbolName: name, accessibilityDescription: nil),
            let sized = base.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
            )
        else { return nil }

        let image = NSImage(size: sized.size)
        image.lockFocus()
        sized.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
        NSColor.white.set()
        NSRect(origin: .zero, size: sized.size).fill(using: .sourceAtop)
        image.unlockFocus()
        return image
    }
}
