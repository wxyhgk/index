import AppKit

// 三个最简单的形状工具：拖一个矩形、按外接框命中、八个控制点，
// 契约的默认实现全部够用，各自只补一句绘制。

struct RectTool: AnnotationToolDescriptor {
    let tool = AnnotationTool.rect
    let axes: [ToolStyleAxis] = [.color, .width]
    let defaultStyle = ToolStyle()
    let shortcut: (keyCode: UInt16, label: String)? = (KeyCode.r, "R")
    let isPinnedToBar = true

    func draw(_ layer: Layer, in ctx: CGContext) {
        ctx.setStrokeColor(layer.color.cg)
        ctx.setLineWidth(layer.lineWidth)
        ctx.stroke(layer.rect.cg)
    }
}

struct EllipseTool: AnnotationToolDescriptor {
    let tool = AnnotationTool.ellipse
    let axes: [ToolStyleAxis] = [.color, .width]
    let defaultStyle = ToolStyle()
    let shortcut: (keyCode: UInt16, label: String)? = (KeyCode.o, "O")

    func draw(_ layer: Layer, in ctx: CGContext) {
        ctx.setStrokeColor(layer.color.cg)
        ctx.setLineWidth(layer.lineWidth)
        ctx.strokeEllipse(in: layer.rect.cg)
    }
}

/// 荧光笔。默认橙色是它的直觉色；透明度是它自己那根轴（造层时已压进
/// `color.a`），不再是写死的 0.4。正片叠底才有荧光笔盖在文字上的观感。
struct HighlightTool: AnnotationToolDescriptor {
    let tool = AnnotationTool.highlight
    let axes: [ToolStyleAxis] = [.color, .opacity]
    let defaultStyle = ToolStyle(colorIndex: 1)
    let shortcut: (keyCode: UInt16, label: String)? = (KeyCode.h, "H")

    func draw(_ layer: Layer, in ctx: CGContext) {
        ctx.saveGState()
        ctx.setBlendMode(.multiply)
        ctx.setFillColor(layer.color.cg)
        ctx.fill(layer.rect.cg)
        ctx.restoreGState()
    }
}
