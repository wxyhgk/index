import AppKit

/// 橡皮擦：拖动擦除路径经过的标注层。
/// 不产生新图层；交互走标准 .drag 流程（beginDraw → updateDraw → endDraw），
/// 但 updateDraw 中擦除命中层，endDraw 中不提交新层。
struct EraserTool: AnnotationToolDescriptor {
    let tool = AnnotationTool.eraser
    let axes: [ToolStyleAxis] = [.width]
    let defaultStyle = ToolStyle(widthIndex: 5)
    let input = ToolInput.drag
    let shortcut: (keyCode: UInt16, label: String)? = (KeyCode.e, "E")
    let isPinnedToBar = false

    /// 橡皮擦不产生图层，返回一个零尺寸占位层（endDraw 中会跳过提交）。
    func makeLayer(_ context: ToolLayerContext) -> Layer {
        baseLayer(context)
    }

    func hitTest(_ layer: Layer, at point: CGPoint, tolerance: Double) -> Bool {
        false
    }

    var resizeHandles: [ResizeHandle] { [] }

    func draw(_ layer: Layer, in ctx: CGContext) {}
}
