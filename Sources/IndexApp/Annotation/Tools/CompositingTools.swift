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
    let axes: [ToolStyleAxis] = [.blockSize]
    let defaultStyle = ToolStyle()
    let shortcut: (keyCode: UInt16, label: String)? = (KeyCode.p, "P")
    let isPinnedToBar = true
}

/// 裁剪。没有任何可调样式。
struct CropTool: AnnotationToolDescriptor {
    let tool = AnnotationTool.crop
    let axes: [ToolStyleAxis] = []
    let defaultStyle = ToolStyle()
    // C 被取色器占用，裁剪用 X。
    let shortcut: (keyCode: UInt16, label: String)? = (KeyCode.x, "X")
}

/// 聚光灯：矩形亮区，区域外整体压暗。
struct SpotlightTool: AnnotationToolDescriptor {
    let tool = AnnotationTool.spotlight
    let axes: [ToolStyleAxis] = [.dim]
    let defaultStyle = ToolStyle()
    // 裸 S 选聚光灯；⌘S 在两处键盘路由里都先判修饰键，保存不受影响。
    let shortcut: (keyCode: UInt16, label: String)? = (KeyCode.s, "S")

    /// 所有聚光灯合成一张遮罩，画在其余矢量层之下 —— 否则标注本身也会被压暗。
    let drawsMerged = true

    /// 整个可绘制区域铺一层半透明黑，再把每个聚光灯矩形挖亮。
    /// 用透明图层 + destinationOut 挖洞，而不是 even-odd —— 两个聚光灯重叠时
    /// even-odd 会把交集重新填黑，挖洞则不管怎么叠都是亮的。
    func drawMerged(_ layers: [Layer], in ctx: CGContext) {
        // 上下文此刻已是图层坐标系；裁剪盒就是「当前可见的画布范围」：
        // 离屏导出时是整张图，覆盖层预览时是选区。
        let canvas = ctx.boundingBoxOfClipPath
        guard !canvas.isEmpty else { return }

        // 压暗程度是**画布级**属性而非单层属性（只有一次整体填充），
        // 多个聚光灯时以最后画的那个为准 —— 「我刚调的那个说了算」最好预期。
        // 旧图层没有 dim 字段（nil）→ 0.55 → 与从前一致。
        let dim = layers.last?.dim ?? 0.55

        ctx.saveGState()
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.setFillColor(CGColor(gray: 0, alpha: dim))
        ctx.fill(canvas)
        ctx.setBlendMode(.destinationOut)
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        for layer in layers {
            let rect = layer.rect.cg
            if rect.width >= 1, rect.height >= 1 {
                ctx.fill(rect)
            }
        }
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }
}
