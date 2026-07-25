import AppKit

/// 选区覆盖层的全部绘制逻辑。无状态 —— 输入模型，输出像素。
enum OverlayRenderer {

    @MainActor
    static func draw(
        model: SelectionModel,
        buttons: [ToolbarButton],
        hoveredAction: CaptureAction?,
        isPrimaryScreen: Bool,
        in bounds: CGRect,
        ctx: CGContext
    ) {
        // 冻结画面本身由 CALayer 承载，这里**绝不重画位图** ——
        // 拖拽时每帧重采样一张 4K 位图会直接把主线程压垮。
        // 压暗用「整屏 + 选区」的 even-odd 路径一次填充，纯平色，几乎零成本。
        let dimPath = NSBezierPath(rect: bounds)
        let globalRect = model.activeRect.flatMap { $0.isEmpty ? nil : $0 }
        let local = globalRect.map { toLocal($0, in: model) }

        if let local {
            dimPath.appendRect(local)
            dimPath.windingRule = .evenOdd
        }
        NSColor.black.withAlphaComponent(0.42).setFill()
        dimPath.fill()

        guard let globalRect, let local else {
            if isPrimaryScreen && !model.isInactive {
                drawHint(in: bounds)
            }
            return
        }

        let isWindowHint = model.isWindowHint
        ctx.setStrokeColor((isWindowHint ? NSColor.systemBlue : NSColor.white).cgColor)
        ctx.setLineWidth(isWindowHint ? 3 : 1.5)
        ctx.stroke(local.insetBy(dx: -0.75, dy: -0.75))

        drawSizeLabel(
            for: globalRect,
            near: local,
            ownerName: isWindowHint ? model.hoveredWindow?.ownerName : nil,
            scale: model.snapshot.scale,
            in: bounds
        )

        if model.showsHandles {
            drawHandles(in: local)
        }

        if model.phase == .confirmed {
            drawToolbar(buttons, hovered: hoveredAction)
        }
    }

    /// 8 个调整控制点。选区太小时只画四角，否则会糊成一团。
    private static func drawHandles(in local: CGRect) {
        let size: CGFloat = 7
        let cornersOnly = local.width < 40 || local.height < 40

        let handles: [SelectionModel.Handle] = cornersOnly
            ? [.topLeft, .topRight, .bottomRight, .bottomLeft]
            : SelectionModel.Handle.resizeHandles

        for handle in handles {
            let center = handle.point(in: local)
            let box = NSRect(
                x: center.x - size / 2,
                y: center.y - size / 2,
                width: size,
                height: size
            )
            let path = NSBezierPath(roundedRect: box, xRadius: 1.5, yRadius: 1.5)
            NSColor.white.setFill()
            path.fill()
            NSColor.black.withAlphaComponent(0.45).setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }

    // MARK: - 坐标

    @MainActor
    private static func toLocal(_ global: CGRect, in model: SelectionModel) -> CGRect {
        CGRect(
            x: global.origin.x - model.bounds.origin.x,
            y: global.origin.y - model.bounds.origin.y,
            width: global.width,
            height: global.height
        )
    }

    // MARK: - 局部元素

    private static func drawHint(in bounds: CGRect) {
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

    private static func drawSizeLabel(
        for globalRect: CGRect,
        near local: CGRect,
        ownerName: String?,
        scale: CGFloat,
        in bounds: CGRect
    ) {
        var text = "\(Int(globalRect.width * scale)) × \(Int(globalRect.height * scale))"
        if let ownerName {
            text = "\(ownerName)  \(text)"
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

    private static func drawToolbar(_ buttons: [ToolbarButton], hovered: CaptureAction?) {
        guard let barRect = ToolbarLayout.barFrame(of: buttons) else { return }

        NSColor(calibratedWhite: 0.13, alpha: 0.96).setFill()
        let path = NSBezierPath(roundedRect: barRect, xRadius: 8, yRadius: 8)
        path.fill()
        NSColor.white.withAlphaComponent(0.14).setStroke()
        path.lineWidth = 1
        path.stroke()

        let (padding, iconSize, iconGap) = ToolbarLayout.contentInsets
        let attrs: [NSAttributedString.Key: Any] = [
            .font: ToolbarLayout.labelFont,
            .foregroundColor: NSColor.white
        ]

        for button in buttons {
            if hovered == button.action {
                NSColor.controlAccentColor.withAlphaComponent(0.85).setFill()
                NSBezierPath(
                    roundedRect: button.frame.insetBy(dx: 2.5, dy: 3.5),
                    xRadius: 5, yRadius: 5
                ).fill()
            }

            if let icon = symbolImage(
                button.action.symbolName,
                pointSize: ToolbarLayout.iconPointSize,
                tint: .white
            ) {
                icon.draw(in: CGRect(
                    x: button.frame.minX + padding,
                    y: button.frame.midY - icon.size.height / 2,
                    width: icon.size.width,
                    height: icon.size.height
                ))
            }

            let title = button.action.title as NSString
            let textSize = title.size(withAttributes: attrs)
            title.draw(
                at: NSPoint(
                    x: button.frame.minX + padding + iconSize + iconGap,
                    y: button.frame.midY - textSize.height / 2
                ),
                withAttributes: attrs
            )
        }
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
