import AppKit

/// 即时标注的状态机。截图覆盖层和钉图窗口共用同一个实例类型 ——
/// 两处的工具、颜色、粗细、撤销行为因此完全一致。
///
/// 坐标用调用方定义的「画布空间」，唯一约定是**左上原点、Y 向下**，
/// 和 `LayerRenderer` 的假设一致，所以预览和导出能共用同一份绘制代码。
///   · 截图覆盖层：显示器局部、点（不依赖选区原点，选区被拖动也不会让标注错位）
///   · 钉图窗口：  图片像素
@MainActor
final class AnnotationState {

    nonisolated static let palette: [LColor] = [
        LColor(r: 0.98, g: 0.22, b: 0.22, a: 1),   // 红
        LColor(r: 1.00, g: 0.72, b: 0.10, a: 1),   // 橙
        LColor(r: 0.20, g: 0.55, b: 0.98, a: 1),   // 蓝
        LColor(r: 1.00, g: 1.00, b: 1.00, a: 1)    // 白
    ]
    nonisolated static let widths: [Double] = [2, 4, 8]

    /// nil 表示指针模式：拖拽是调整选区，而不是画标注。
    var tool: AnnotationTool?
    var colorIndex: Int
    var widthIndex: Int

    /// 画布空间相对屏幕点的倍率。笔宽和字号按它换算，
    /// 这样不管画布怎么缩放，画出来的线在屏幕上都是同样粗细。
    var strokeScale: Double = 1

    private(set) var layers: [Layer] = []
    private(set) var editingTextID: UUID?

    /// 每个马赛克图层对应一张预先算好的小图。
    /// 绝不在每帧重跑 CoreImage —— 那是上一轮把主线程压垮的同一类错误。
    private(set) var pixelatePreviews: [UUID: CGImage] = [:]

    private var dragStart: CGPoint?
    private var dragCurrent: CGPoint?

    init() {
        let settings = AppSettings.shared
        colorIndex = Self.palette.indices.contains(settings.defaultColorIndex)
            ? settings.defaultColorIndex : 0
        widthIndex = Self.widths.indices.contains(settings.defaultWidthIndex)
            ? settings.defaultWidthIndex : 1
    }

    var color: LColor { Self.palette[colorIndex] }
    var lineWidth: Double { Self.widths[widthIndex] * strokeScale }
    var fontSize: Double { (Self.widths[widthIndex] * 4 + 8) * strokeScale }

    var isEmpty: Bool { layers.isEmpty }
    var isDrawing: Bool { dragStart != nil }
    var isEditingText: Bool { editingTextID != nil }

    // MARK: - 绘制中的图层

    private var pendingLayer: Layer? {
        guard let tool, let a = dragStart, let b = dragCurrent else { return nil }
        return makeLayer(tool: tool, from: a, to: b)
    }

    /// 交给渲染层的完整列表：已提交的 + 正在拖的；正在输入的文字带一个光标。
    var displayLayers: [Layer] {
        var result = layers
        if let editingTextID, let index = result.firstIndex(where: { $0.id == editingTextID }) {
            result[index].text += "|"
        }
        if let pendingLayer {
            result.append(pendingLayer)
        }
        return result
    }

    private func makeLayer(tool: AnnotationTool, from a: CGPoint, to b: CGPoint) -> Layer {
        var c = color
        if tool == .highlight { c.a = 0.4 }
        return Layer(
            kind: tool.layerKind,
            rect: LRect(from: a, to: b),
            color: c,
            lineWidth: lineWidth,
            text: "",
            fontSize: fontSize
        )
    }

    // MARK: - 输入

    /// 文字工具是点击落点，其余是拖拽。返回是否需要重绘。
    @discardableResult
    func beginDraw(at point: CGPoint) -> Bool {
        guard let tool else { return false }
        endTextEditing()

        if tool == .text {
            var layer = makeLayer(tool: .text, from: point, to: point)
            layer.text = ""
            layers.append(layer)
            editingTextID = layer.id
            return true
        }

        dragStart = point
        dragCurrent = point
        return true
    }

    @discardableResult
    func updateDraw(to point: CGPoint) -> Bool {
        guard dragStart != nil else { return false }
        dragCurrent = point
        return true
    }

    /// 提交正在拖的图层。
    /// - Parameter pixelSource: 给定画布空间的矩形，返回该区域的原始像素 ——
    ///   只有马赛克需要，用来预先算好贴片。截图覆盖层从冻结画面取，钉图窗口从底图取。
    @discardableResult
    func endDraw(pixelSource: (CGRect) -> CGImage?) -> Bool {
        defer {
            dragStart = nil
            dragCurrent = nil
        }
        guard let layer = pendingLayer else { return false }

        let r = layer.rect.cg
        guard r.width >= 2 || r.height >= 2 else { return false }

        if layer.kind == .pixelate {
            pixelatePreviews[layer.id] = pixelSource(r).flatMap(LayerRenderer.pixelated)
        }
        layers.append(layer)
        return true
    }

    /// 丢弃全部标注，回到干净状态。
    func clear() {
        endTextEditing()
        layers.removeAll()
        pixelatePreviews.removeAll()
    }

    // MARK: - 文字输入

    func insertText(_ text: String) {
        guard let editingTextID,
              let index = layers.firstIndex(where: { $0.id == editingTextID }) else { return }
        layers[index].text += text
    }

    func deleteBackward() {
        guard let editingTextID,
              let index = layers.firstIndex(where: { $0.id == editingTextID }),
              !layers[index].text.isEmpty else { return }
        layers[index].text.removeLast()
    }

    /// 结束输入。空文字图层直接丢弃，避免留下看不见的空壳。
    func endTextEditing() {
        guard let id = editingTextID else { return }
        editingTextID = nil
        if let index = layers.firstIndex(where: { $0.id == id }), layers[index].text.isEmpty {
            layers.remove(at: index)
        }
    }

    // MARK: - 撤销

    @discardableResult
    func undo() -> Bool {
        endTextEditing()
        guard let last = layers.popLast() else { return false }
        pixelatePreviews[last.id] = nil
        return true
    }

    // MARK: - 导出

    /// 从「显示器局部、点」换算到「裁剪图的像素」。只有截图覆盖层需要 ——
    /// 钉图窗口的画布空间本来就是图片像素。
    /// - Parameter selection: 选区，显示器局部左上原点、点。
    func exportLayers(selection: CGRect, scale: CGFloat) -> [Layer] {
        layers.map { layer in
            var copy = layer
            copy.rect = LRect(
                x: (layer.rect.x - selection.minX) * scale,
                y: (layer.rect.y - selection.minY) * scale,
                w: layer.rect.w * scale,
                h: layer.rect.h * scale
            )
            copy.lineWidth = layer.lineWidth * scale
            copy.fontSize = layer.fontSize * scale
            return copy
        }
    }
}
