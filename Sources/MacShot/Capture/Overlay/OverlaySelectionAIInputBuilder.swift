import CoreGraphics

/// 从 Capture Overlay 当前“用户可见内容”构造 AI 输入。
///
/// 先裁出用户明确选择的局部像素，再只合成实际显示在截图画布上的标注图层。
/// 这样既不为小选区创建整张 4K 合成图，也能保证马赛克遮挡后的原始像素不会
/// 被 Provider 看见。裁剪、外壳、水印、美化等成品效果不属于当前局部画布。
enum OverlaySelectionAIInputBuilder {
    @MainActor
    static func makeInput(
        model: SelectionModel,
        annotation: AnnotationState,
        geometry: OverlayGeometry,
        transform: OverlaySelectionAITransform,
        selectionRect: CGRect
    ) -> SelectionAIInput? {
        guard let confirmedRect = model.confirmedRect else { return nil }

        let snapshotBounds = CGRect(
            x: 0,
            y: 0,
            width: model.snapshot.image.width,
            height: model.snapshot.image.height
        )
        let selectedInSnapshot = selectionRect
            .offsetBy(dx: transform.cropPixelRect.minX, dy: transform.cropPixelRect.minY)
            .integral
            .intersection(snapshotBounds)
        guard selectedInSnapshot.width >= 1,
              selectedInSnapshot.height >= 1,
              let sharedCrop = model.snapshot.image.cropping(to: selectedInSnapshot)
        else { return nil }
        let base = detached(sharedCrop)

        let projected = annotation.exportLayers(
            selection: geometry.annotationRect(fromGlobal: confirmedRect),
            scale: model.snapshot.scale
        )
        let relativeOrigin = CGPoint(
            x: selectedInSnapshot.minX - transform.cropPixelRect.minX,
            y: selectedInSnapshot.minY - transform.cropPixelRect.minY
        )
        let visibleLayers = Layers<ImageSpace>(projected.elements.compactMap { layer in
            guard layer.kind != .crop, !layer.kind.isEffect else { return nil }
            var copy = layer
            copy.rect = LRect(
                x: layer.rect.x - relativeOrigin.x,
                y: layer.rect.y - relativeOrigin.y,
                w: layer.rect.w,
                h: layer.rect.h
            )
            return copy
        })
        let visible = visibleLayers.isEmpty
            ? base
            : LayerRenderer.render(base: base, layers: visibleLayers)

        return SelectionAIInput(image: visible)
    }

    /// `cropping(to:)` 可能共享整张截图的后备存储；复制后请求只保留局部像素。
    private static func detached(_ image: CGImage) -> CGImage {
        guard let context = CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage() ?? image
    }
}
