import AppKit

/// 图层的实时预览绘制。截图覆盖层和钉图窗口共用这一份 ——
/// 加上导出走的 `LayerRenderer`，三处的矢量绘制其实是同一段代码。
enum AnnotationRenderer {

    /// - Important: 传入的上下文必须**已经**是「左上原点、Y 向下」，
    ///   并且单位与图层坐标一致。调用方负责设好 CTM。
    static func draw(
        _ layers: [Layer],
        pixelatePreviews: [UUID: CGImage],
        in ctx: CGContext
    ) {
        for layer in layers where layer.kind == .pixelate {
            drawPixelate(layer, preview: pixelatePreviews[layer.id], in: ctx)
        }
        LayerRenderer.drawVectors(layers, in: ctx)
    }

    /// 马赛克贴片是图层提交时预先算好的；正在拖的那个还没有，先用灰块占位。
    /// 绝不在每帧重跑 CoreImage。
    private static func drawPixelate(_ layer: Layer, preview: CGImage?, in ctx: CGContext) {
        let rect = layer.rect.cg
        guard rect.width >= 1, rect.height >= 1 else { return }

        guard let preview else {
            ctx.setFillColor(NSColor(calibratedWhite: 0.55, alpha: 0.9).cgColor)
            ctx.fill(rect)
            return
        }

        // 上下文此刻是 Y 向下的，画位图要再翻一次。
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(preview, in: CGRect(origin: .zero, size: rect.size))
        ctx.restoreGState()
    }
}
