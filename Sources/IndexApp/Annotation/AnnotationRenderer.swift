import AppKit

/// 图层的实时预览绘制。截图覆盖层和钉图窗口共用这一份 ——
/// 加上导出走的 `LayerRenderer`，三处的矢量绘制其实是同一段代码。
enum AnnotationRenderer {

    /// - Important: 传入的上下文必须**已经**是「左上原点、Y 向下」，
    ///   并且单位与图层坐标一致。调用方负责设好 CTM。
    ///
    /// 美化层（backdrop）、外壳层（frame）与捕获信息层（captureInfo）在这里被
    /// 整体跳过 —— 编辑时画布尺寸不变，背景垫底 / 圆角 / 阴影 / 窗口壳 / 底部
    /// 信息栏只在导出路径（`LayerRenderer.render`）生效。这是刻意的取舍：
    /// 实时预览若要显示它们，画布要随开关变尺寸，
    /// 选区/钉图窗口的几何都会被牵连；工具条开关的高亮已足够表达状态。
    static func draw<Space: LayerSpace>(
        _ layers: Layers<Space>,
        pixelatePreviews: [UUID: CGImage],
        baseImage: CGImage? = nil,
        canvasSize: CGSize = .zero,
        in ctx: CGContext
    ) {
        for layer in layers.elements {
            guard let descriptor = ToolRegistry.descriptor(for: layer.kind) else { continue }
            descriptor.drawBelow(layer, preview: pixelatePreviews[layer.id], baseImage: baseImage, canvasSize: canvasSize, in: ctx)
        }
        LayerRenderer.drawVectors(layers.elements, in: ctx)

        // 参与预览的效果层（描述符带 `previewDraw` 的，目前只有水印 ——
        // 它盖在画面上，影响构图判断）。位置相对「成品范围」：这里取当前裁剪盒
        // （覆盖层是选区，钉图/编辑器是整张图），与导出时相对裁剪后整图的定位一致；
        // 绘制代码就是导出用的那一份。和 `LayerRenderer.render` 一样只认最后一层 ——
        // 钉图把截图时的水印和新开的水印叠在一个列表里时，预览和导出取的是同一层。
        for descriptor in EffectRegistry.ordered {
            guard let previewDraw = descriptor.previewDraw,
                  let layer = layers.elements.last(where: { $0.kind == descriptor.kind })
            else { continue }
            previewDraw(layer, ctx, ctx.boundingBoxOfClipPath)
        }
    }

    /// 选中图层的虚线外框 + 缩放控制点。和图层画在同一个（左上原点、Y 向下的）
    /// 上下文里；`strokeScale` 是画布单位相对屏幕点的倍率，保证虚线在屏幕上
    /// 总是 1pt 粗、控制点总是同样大小。
    static func drawSelectionHint<Space: LayerSpace>(
        selectedID: UUID?,
        layers: Layers<Space>,
        strokeScale: CGFloat,
        in ctx: CGContext
    ) {
        guard let selectedID, let index = layers.firstIndex(id: selectedID) else { return }
        let layer = layers[index]
        // text 的 rect 只存锚点，虚线框按量出的文字范围画；其余就是 rect 本身。
        let box = layer.handleBounds.insetBy(dx: -3 * strokeScale, dy: -3 * strokeScale)

        ctx.saveGState()
        ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
        ctx.setLineWidth(1.5 * strokeScale)
        ctx.stroke(box)
        ctx.restoreGState()

        drawResizeHandles(for: layer, strokeScale: strokeScale, in: ctx)
    }

    /// 拖动时的对齐参考线：红色细线贯穿整个画布。
    static func drawAlignmentGuides(
        _ guides: [AnnotationState.AlignmentGuide],
        strokeScale: CGFloat,
        in ctx: CGContext
    ) {
        guard !guides.isEmpty else { return }
        let canvas = ctx.boundingBoxOfClipPath
        ctx.saveGState()
        ctx.setStrokeColor(NSColor.systemRed.withAlphaComponent(0.8).cgColor)
        ctx.setLineWidth(1 * strokeScale)
        for guide in guides {
            if guide.isHorizontal {
                ctx.move(to: CGPoint(x: canvas.minX, y: guide.position))
                ctx.addLine(to: CGPoint(x: canvas.maxX, y: guide.position))
            } else {
                ctx.move(to: CGPoint(x: guide.position, y: canvas.minY))
                ctx.addLine(to: CGPoint(x: guide.position, y: canvas.maxY))
            }
        }
        ctx.strokePath()
        ctx.restoreGState()
    }

    /// 缩放控制点：矩形类 8 个小方块（样式参照选区的 `OverlayRenderer.drawHandles`：
    /// 白底、黑描边、微圆角），line / arrow 只画两端圆点。尺寸随 `strokeScale`。
    private static func drawResizeHandles(for layer: Layer, strokeScale: CGFloat, in ctx: CGContext) {
        let handles = ResizeHandle.handles(for: layer.kind)
        guard !handles.isEmpty else { return }

        let size = 7 * strokeScale
        // 画成端点圆点还是方块，由工具自己声明（见 `AnnotationToolDescriptor`）。
        let isEndpoint = ToolRegistry.descriptor(for: layer.kind)?.usesEndpointHandles ?? false

        ctx.saveGState()
        ctx.setLineWidth(strokeScale)
        for handle in handles {
            let center = handle.location(of: layer)
            let box = CGRect(
                x: center.x - size / 2,
                y: center.y - size / 2,
                width: size,
                height: size
            )
            let path: CGPath = isEndpoint
                ? CGPath(ellipseIn: box, transform: nil)
                : CGPath(
                    roundedRect: box,
                    cornerWidth: 1.5 * strokeScale,
                    cornerHeight: 1.5 * strokeScale,
                    transform: nil
                )
            ctx.addPath(path)
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fillPath()
            ctx.addPath(path)
            ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.45))
            ctx.strokePath()
        }
        ctx.restoreGState()
    }

}
