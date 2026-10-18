import CoreGraphics

/// 带壳预览卡片的布局。纯几何，方便测试，不碰 AppKit 视图。
///
/// 位置策略固定：优先贴选区右侧并垂直居中；右侧放不下才翻到左侧。
/// 不再在上/下/角之间跳。
enum FramePreviewLayout {
    static let maxPanelWidth: CGFloat = 300
    static let maxPanelHeight: CGFloat = 260
    static let gap: CGFloat = 14
    static let margin: CGFloat = 12

    /// 只算「右侧 / 左侧」两个候选；都放不下时退回屏幕右上角并夹紧。
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
        var panelHeight = panelWidth / aspect
        if panelHeight > maxPanelHeight {
            panelHeight = min(maxPanelHeight, max(90, bounds.height * 0.36))
            panelWidth = panelHeight * aspect
        }
        panelWidth = min(max(panelWidth, 100), max(100, bounds.width - 2 * margin))
        panelHeight = min(max(panelHeight, 70), max(70, bounds.height - 2 * margin))

        let y = selection.midY - panelHeight / 2
        let right = CGRect(
            x: selection.maxX + gap,
            y: y,
            width: panelWidth,
            height: panelHeight
        )
        let left = CGRect(
            x: selection.minX - gap - panelWidth,
            y: y,
            width: panelWidth,
            height: panelHeight
        )

        let rightFits = right.maxX <= bounds.maxX - margin
        let leftFits = left.minX >= bounds.minX + margin
        let obstacleZones = obstacles.map { $0.insetBy(dx: -6, dy: -6) }

        // 右侧优先；若右侧被工具条挡住，而左侧可用，则翻左。
        if rightFits {
            let clamped = clamp(right, in: bounds)
            if obstacleZones.allSatisfy({ !$0.intersects(clamped) }) || !leftFits {
                return clamped
            }
        }
        if leftFits {
            return clamp(left, in: bounds)
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

    /// 卡片没有标题栏，缩略图直接铺满；保留这个函数是为了统一处理
    /// 极端长宽比（面板被上限裁剪时仍按 aspect-fit 居中）。
    static func imageRect(in panel: CGRect, imageSize: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0,
              panel.width > 0, panel.height > 0
        else { return .zero }
        let aspect = imageSize.width / imageSize.height
        var width = panel.width
        var height = width / aspect
        if height > panel.height {
            height = panel.height
            width = height * aspect
        }
        return CGRect(
            x: panel.midX - width / 2,
            y: panel.midY - height / 2,
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
