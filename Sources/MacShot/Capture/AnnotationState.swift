import AppKit

enum AnnotationTool: CaseIterable {
    case rect
    case ellipse
    case arrow
    case text
    case highlight
    case pixelate

    var layerKind: Layer.Kind {
        switch self {
        case .rect: return .rect
        case .ellipse: return .ellipse
        case .arrow: return .arrow
        case .text: return .text
        case .highlight: return .highlight
        case .pixelate: return .pixelate
        }
    }

    var symbolName: String { layerKind.symbolName }
    var title: String { layerKind.displayName }
}

/// 截图覆盖层里的即时标注。
///
/// 坐标一律用「显示器局部、左上原点、点」—— 和 `LayerRenderer` 的假设一致，
/// 于是预览和最终导出可以共用同一份绘制代码，天然所见即所得。
/// 也因为它不依赖选区原点，选区之后被拖动也不会让已画的标注错位。
@MainActor
final class AnnotationState {

    nonisolated static let palette: [LColor] = [
        LColor(r: 0.98, g: 0.22, b: 0.22, a: 1),   // 红
        LColor(r: 1.00, g: 0.72, b: 0.10, a: 1),   // 橙
        LColor(r: 0.20, g: 0.78, b: 0.35, a: 1),   // 绿
        LColor(r: 0.20, g: 0.55, b: 0.98, a: 1),   // 蓝
        LColor(r: 1.00, g: 1.00, b: 1.00, a: 1)    // 白
    ]
    nonisolated static let widths: [Double] = [2, 4, 8]

    /// nil 表示指针模式：拖拽是调整选区，而不是画标注。
    var tool: AnnotationTool?
    var colorIndex = 0
    var widthIndex = 1

    private(set) var layers: [Layer] = []
    private(set) var editingTextID: UUID?

    /// 每个马赛克图层对应一张预先算好的小图。
    /// 绝不在每帧重跑 CoreImage —— 那是上一轮把主线程压垮的同一类错误。
    private(set) var pixelatePreviews: [UUID: CGImage] = [:]

    private var dragStart: CGPoint?
    private var dragCurrent: CGPoint?

    var color: LColor { Self.palette[colorIndex] }
    var lineWidth: Double { Self.widths[widthIndex] }
    var fontSize: Double { lineWidth * 4 + 8 }

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

    /// 提交正在拖的图层。`snapshot` 用来给马赛克预先算好像素。
    @discardableResult
    func endDraw(in snapshot: DisplaySnapshot) -> Bool {
        defer {
            dragStart = nil
            dragCurrent = nil
        }
        guard let layer = pendingLayer else { return false }

        let r = layer.rect.cg
        guard r.width >= 2 || r.height >= 2 else { return false }

        if layer.kind == .pixelate {
            pixelatePreviews[layer.id] = makePixelatePreview(for: r, in: snapshot)
        }
        layers.append(layer)
        return true
    }

    private func makePixelatePreview(for rect: CGRect, in snapshot: DisplaySnapshot) -> CGImage? {
        // 显示器局部左上原点 → AppKit 全局
        let global = CGRect(
            x: snapshot.frame.minX + rect.minX,
            y: snapshot.frame.maxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
        guard let piece = snapshot.crop(globalRect: global) else { return nil }
        return LayerRenderer.pixelated(piece)
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

    /// 转换到「裁剪图的像素坐标」。
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
