import CoreGraphics

/// 带壳预览卡片的布局。纯几何，方便测试，不碰 AppKit 视图。
enum FramePreviewLayout {
    static let headerHeight: CGFloat = 26
    static let padding: CGFloat = 8
    static let maxPanelWidth: CGFloat = 300
    static let maxPanelHeight: CGFloat = 280
    static let gap: CGFloat = 14
    static let margin: CGFloat = 12

    /// 在选区四周找一个不与选区、工具条重叠的位置；都放不下就退回右上角并夹紧。
    static func panelRect(
        imageSize: CGSize,
        bounds: CGRect,
        selection: CGRect,
        obstacles: [CGRect]
    ) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0,
              bounds.width > 0, bounds.height > 0
        else { return .zero }

        let aspect = imageSize.width / imageSize.height
        var panelWidth = min(maxPanelWidth, max(140, bounds.width * 0.28))
        var panelHeight = (panelWidth - 2 * padding) / aspect + 2 * padding + headerHeight
        if panelHeight > maxPanelHeight {
            panelHeight = min(maxPanelHeight, max(100, bounds.height * 0.36))
            panelWidth = (panelHeight - 2 * padding - headerHeight) * aspect + 2 * padding
        }
        panelWidth = min(max(panelWidth, 120), max(120, bounds.width - 2 * margin))
        panelHeight = min(max(panelHeight, 90), max(90, bounds.height - 2 * margin))

        let candidates = [
            CGRect(x: selection.maxX + gap, y: selection.maxY - panelHeight,
                   width: panelWidth, height: panelHeight),
            CGRect(x: selection.maxX + gap, y: selection.minY,
                   width: panelWidth, height: panelHeight),
            CGRect(x: selection.minX - gap - panelWidth, y: selection.maxY - panelHeight,
                   width: panelWidth, height: panelHeight),
            CGRect(x: selection.minX - gap - panelWidth, y: selection.minY,
                   width: panelWidth, height: panelHeight),
            CGRect(x: selection.midX - panelWidth / 2, y: selection.minY - gap - panelHeight,
                   width: panelWidth, height: panelHeight),
            CGRect(x: selection.midX - panelWidth / 2, y: selection.maxY + gap,
                   width: panelWidth, height: panelHeight)
        ]

        let selectionZone = selection.insetBy(dx: -4, dy: -4)
        let obstacleZones = obstacles.map { $0.insetBy(dx: -6, dy: -6) }

        for candidate in candidates {
            let clamped = clamp(candidate, in: bounds)
            if !clamped.intersects(selectionZone),
               obstacleZones.allSatisfy({ !$0.intersects(clamped) }) {
                return clamped
            }
        }

        return clamp(
            CGRect(
                x: bounds.maxX - margin - panelWidth,
                y: bounds.maxY - margin - panelHeight,
                width: panelWidth,
                height: panelHeight
            ),
            in: bounds
        )
    }

    /// 标题栏下方的图片区，按 aspect-fit 居中。
    static func imageRect(in panel: CGRect, imageSize: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let area = CGRect(
            x: panel.minX + padding,
            y: panel.minY + padding,
            width: panel.width - 2 * padding,
            height: panel.height - 2 * padding - headerHeight
        )
        guard area.width > 0, area.height > 0 else { return .zero }
        let aspect = imageSize.width / imageSize.height
        var width = area.width
        var height = width / aspect
        if height > area.height {
            height = area.height
            width = height * aspect
        }
        return CGRect(
            x: area.midX - width / 2,
            y: area.midY - height / 2,
            width: width,
            height: height
        )
    }

    private static func clamp(_ rect: CGRect, in bounds: CGRect) -> CGRect {
        var result = rect
        result.origin.x = min(
            max(result.minX, bounds.minX + margin),
            max(bounds.minX + margin, bounds.maxX - margin - result.width)
        )
        result.origin.y = min(
            max(result.minY, bounds.minY + margin),
            max(bounds.minY + margin, bounds.maxY - margin - result.height)
        )
        return result
    }
}
