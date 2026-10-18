import AppKit

// 三个不走「逐层矢量绘制」的工具。它们的呈现是渲染管线里的整图操作，
// 契约的 `draw` 默认空实现正好合适：
//
//   马赛克   图像级滤镜，必须在画矢量层**之前**作用到底图上
//   裁剪     改的是画布本身，永远最后应用，且只影响输出
//   聚光灯   多层合并成一张遮罩，画在其余矢量层**之下**（走 `drawMerged`）
//
// 前两者留在 `LayerRenderer.render` 的一、二两步 —— 那是管线阶段而不是绘制，
// 形状上更接近 `EffectDescriptor`。这里只声明它们的交互语义。

/// 马赛克。不吃颜色 —— 渲染根本不读 `layer.color`。
/// 显示靠预先算好的贴片（`LayerRenderer.pixelated`），所以颗粒改了只影响新画的。
struct PixelateTool: AnnotationToolDescriptor {
    let tool = AnnotationTool.pixelate
    let axes: [ToolStyleAxis] = [.blockSize, .pixelateMode]
    let defaultStyle = ToolStyle()
    let shortcut: (keyCode: UInt16, label: String)? = (KeyCode.p, "P")
    let isPinnedToBar = true

    func drawBelow(_ layer: Layer, preview: CGImage?, baseImage: CGImage?, canvasSize: CGSize, in ctx: CGContext) {
        let rect = layer.rect.cg
        guard rect.width >= 1, rect.height >= 1 else { return }
        guard let preview else {
            ctx.setFillColor(NSColor(calibratedWhite: 0.55, alpha: 0.9).cgColor)
            ctx.fill(rect)
            return
        }
        // 上下文是 Y 向下的，画位图要翻转。
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(preview, in: CGRect(origin: .zero, size: rect.size))
        ctx.restoreGState()
    }
}

/// 裁剪。没有任何可调样式。
struct CropTool: AnnotationToolDescriptor {
    let tool = AnnotationTool.crop
    let axes: [ToolStyleAxis] = []
    let defaultStyle = ToolStyle()
    // C 被取色器占用，裁剪用 X。
    let shortcut: (keyCode: UInt16, label: String)? = (KeyCode.x, "X")

    /// 预览阶段画外部压暗 + 虚线框（裁剪本身在导出时 `LayerRenderer.render` 最后一步才生效）。
    func drawBelow(_ layer: Layer, preview: CGImage?, baseImage: CGImage?, canvasSize: CGSize, in ctx: CGContext) {
        let rect = layer.rect.cg
        guard rect.width >= 1, rect.height >= 1 else { return }
        let canvas = ctx.boundingBoxOfClipPath

        ctx.saveGState()
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.45))
        ctx.fill(canvas)
        ctx.setBlendMode(.destinationOut)
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(rect)
        ctx.endTransparencyLayer()
        ctx.restoreGState()

        let width = max(1, layer.lineWidth / 2)
        ctx.saveGState()
        ctx.setLineWidth(width)
        ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.55))
        ctx.stroke(rect)
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.95))
        ctx.setLineDash(phase: 0, lengths: [width * 4, width * 4])
        ctx.stroke(rect)
        ctx.restoreGState()
    }
}

/// 聚光灯：矩形亮区，区域外整体压暗。
struct SpotlightTool: AnnotationToolDescriptor {
    let tool = AnnotationTool.spotlight
    let axes: [ToolStyleAxis] = [.dim]
    let defaultStyle = ToolStyle()
    // 裸 S 选聚光灯；⌘S 在两处键盘路由里都先判修饰键，保存不受影响。
    let shortcut: (keyCode: UInt16, label: String)? = (KeyCode.s, "S")

    /// 所有聚光灯合成遮罩，画在其余矢量层之下 —— 否则标注本身也会被压暗。
    let drawsMerged = true

    /// 每个聚光灯独立压暗：各自铺一层半透明黑再挖自己的亮区。
    /// 重叠区域自然叠加（更暗），选中某层改 dim 只影响那层。
    /// 挖洞用径向渐变实现 feather 羽化边缘（PixPin 风格）。
    func drawMerged(_ layers: [Layer], in ctx: CGContext) {
        let canvas = ctx.boundingBoxOfClipPath
        guard !canvas.isEmpty else { return }

        for layer in layers {
            let dim = layer.dim ?? 0.55
            let rect = layer.rect.cg
            guard rect.width >= 1, rect.height >= 1 else { continue }

            // feather 随区域尺寸缩放：小区域不会吃掉大半亮区
            let feather = min(16, min(rect.width, rect.height) * 0.2)
            // innerRadius 取对角线一半（中心到最远角），保证整个矩形内部完全亮
            let innerRadius = hypot(rect.width / 2, rect.height / 2)
            let outerRadius = innerRadius + feather

            ctx.saveGState()
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            ctx.setFillColor(CGColor(gray: 0, alpha: dim))
            ctx.fill(canvas)

            // 径向渐变挖洞：内部完全透明 → 边缘 feather 过渡
            ctx.setBlendMode(.destinationOut)
            let center = CGPoint(x: rect.midX, y: rect.midY)
            let colors: [CGColor] = [
                CGColor(gray: 0, alpha: 1),
                CGColor(gray: 0, alpha: 0)
            ]
            let locations: [CGFloat] = [0, 1]
            if let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceGray(),
                colors: colors as CFArray,
                locations: locations
            ) {
                ctx.drawRadialGradient(
                    gradient,
                    startCenter: center, startRadius: innerRadius,
                    endCenter: center, endRadius: outerRadius,
                    options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
                )
            }
            ctx.endTransparencyLayer()
            ctx.restoreGState()
        }
    }
}
