import SwiftUI
import AppKit

/// 图层画布。底图 + 图层，用**和导出完全相同**的那段绘制代码渲染。
///
/// 此前编辑器用 SwiftUI `Canvas` 手写了一套近似渲染（箭头、文字都是重写的），
/// 与 `LayerRenderer` 不保证一致 —— 这是「所见非所得」的直接来源。
/// 现在编辑器、截图覆盖层、钉图窗口三处的预览都走 `AnnotationRenderer`。
struct LayerCanvas: NSViewRepresentable {

    /// 底图，已应用提交过的马赛克。
    let image: CGImage
    /// 要绘制的图层，图像像素空间。
    let layers: Layers<ImageSpace>
    /// 正在拖的马赛克没有预算好的贴片，渲染器会画灰块占位。
    let pixelatePreviews: [UUID: CGImage]
    let selectedLayerID: UUID?

    func makeNSView(context: Context) -> CanvasView {
        CanvasView()
    }

    func updateNSView(_ view: CanvasView, context: Context) {
        view.image = image
        view.layers = layers
        view.pixelatePreviews = pixelatePreviews
        view.selectedLayerID = selectedLayerID
        view.needsDisplay = true
    }
}

final class CanvasView: NSView {

    var image: CGImage?
    var layers = Layers<ImageSpace>()
    var pixelatePreviews: [UUID: CGImage] = [:]
    var selectedLayerID: UUID?

    /// 事件由上层的 SwiftUI 手势处理，这里只负责画。
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let image, let ctx = NSGraphicsContext.current?.cgContext else { return }
        guard bounds.width > 0, image.width > 0 else { return }

        ctx.interpolationQuality = .high
        ctx.draw(image, in: bounds)

        let scale = bounds.width / CGFloat(image.width)

        ctx.saveGState()
        // 翻成「图像像素、左上原点、Y 向下」—— 和图层坐标系一致。
        ctx.translateBy(x: 0, y: bounds.height)
        ctx.scaleBy(x: scale, y: -scale)
        AnnotationRenderer.draw(layers, pixelatePreviews: pixelatePreviews, in: ctx)
        ctx.restoreGState()

        drawSelectionHint(scale: scale)
    }

    private func drawSelectionHint(scale: CGFloat) {
        guard let selectedLayerID,
              let layer = layers.elements.first(where: { $0.id == selectedLayerID })
        else { return }

        let r = layer.rect.cg
        let box = NSRect(
            x: r.minX * scale,
            y: bounds.height - r.maxY * scale,
            width: r.width * scale,
            height: r.height * scale
        ).insetBy(dx: -3, dy: -3)

        NSColor.controlAccentColor.setStroke()
        let path = NSBezierPath(rect: box)
        path.lineWidth = 1
        path.setLineDash([3, 3], count: 2, phase: 0)
        path.stroke()
    }
}
