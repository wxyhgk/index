import CoreGraphics

/// 敏感内容检测结果（成品图像素、左上原点）→ 覆盖层标注画布（显示器局部点、左上原点）。
enum PrivacyMaskGeometry {
    static func canvasRects(
        regions: [SensitiveRegion],
        activeRegion: CGRect,
        displayFrame: CGRect,
        scale: CGFloat
    ) -> [CGRect] {
        guard scale > 0, !activeRegion.isEmpty else { return [] }
        let offsetX = activeRegion.minX - displayFrame.minX
        let offsetY = displayFrame.maxY - activeRegion.maxY
        let canvasBounds = CGRect(
            x: offsetX,
            y: offsetY,
            width: activeRegion.width,
            height: activeRegion.height
        )

        return regions.compactMap { region in
            let rect = CGRect(
                x: offsetX + region.rect.minX / scale,
                y: offsetY + region.rect.minY / scale,
                width: region.rect.width / scale,
                height: region.rect.height / scale
            ).intersection(canvasBounds)
            guard rect.width >= 1, rect.height >= 1 else { return nil }
            return rect
        }
    }
}
