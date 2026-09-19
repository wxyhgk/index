import AppKit

// 三个最简单的形状工具：拖一个矩形、按外接框命中、八个控制点，
// 契约的默认实现全部够用，各自只补一句绘制。

struct RectTool: AnnotationToolDescriptor {
    let tool = AnnotationTool.rect
    let axes: [ToolStyleAxis] = [.color, .width, .fillMode]
    let defaultStyle = ToolStyle()
    let shortcut: (keyCode: UInt16, label: String)? = (KeyCode.r, "R")
    let isPinnedToBar = true

    func draw(_ layer: Layer, in ctx: CGContext) {
        let mode = layer.fillMode ?? 0
        let color = layer.color.cg
        switch mode {
        case 1:
            ctx.setFillColor(color)
            ctx.fill(layer.rect.cg)
        case 2:
            ctx.setFillColor(color)
            ctx.fill(layer.rect.cg)
            ctx.setStrokeColor(color)
            ctx.setLineWidth(layer.lineWidth)
            ctx.stroke(layer.rect.cg)
        default:
            ctx.setStrokeColor(color)
            ctx.setLineWidth(layer.lineWidth)
            ctx.stroke(layer.rect.cg)
        }
    }
}

struct EllipseTool: AnnotationToolDescriptor {
    let tool = AnnotationTool.ellipse
    let axes: [ToolStyleAxis] = [.color, .width, .fillMode]
    let defaultStyle = ToolStyle()
    let shortcut: (keyCode: UInt16, label: String)? = (KeyCode.o, "O")

    func draw(_ layer: Layer, in ctx: CGContext) {
        let mode = layer.fillMode ?? 0
        let color = layer.color.cg
        switch mode {
        case 1:
            ctx.setFillColor(color)
            ctx.fillEllipse(in: layer.rect.cg)
        case 2:
            ctx.setFillColor(color)
            ctx.fillEllipse(in: layer.rect.cg)
            ctx.setStrokeColor(color)
            ctx.setLineWidth(layer.lineWidth)
            ctx.strokeEllipse(in: layer.rect.cg)
        default:
            ctx.setStrokeColor(color)
            ctx.setLineWidth(layer.lineWidth)
            ctx.strokeEllipse(in: layer.rect.cg)
        }
    }
}

/// 荧光笔。默认橙色是它的直觉色；透明度是它自己那根轴（造层时已压进
/// `color.a`），不再是写死的 0.4。正片叠底才有荧光笔盖在文字上的观感。
/// 深色底图（alpha 通道不可靠时）退回 normal 混合，避免 multiply 在纯黑上消失。
struct HighlightTool: AnnotationToolDescriptor {
    let tool = AnnotationTool.highlight
    let axes: [ToolStyleAxis] = [.color, .opacity]
    let defaultStyle = ToolStyle(colorIndex: 1)
    let shortcut: (keyCode: UInt16, label: String)? = (KeyCode.h, "H")

    func draw(_ layer: Layer, in ctx: CGContext) {
        ctx.saveGState()
        // multiply 在深色底上几乎不可见（黑 × 任意色 ≈ 黑），
        // 统一用 normal：所有底图上都可见，观感差异可接受。
        ctx.setBlendMode(.normal)
        ctx.setFillColor(layer.color.cg)
        ctx.fill(layer.rect.cg)
        ctx.restoreGState()
    }
}
