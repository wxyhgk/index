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

    private(set) var layers = Layers<CanvasSpace>()
    private(set) var editingTextID: UUID?

    /// 指针模式下选中的图层。选中后可以拖动、删除、改样式。
    private(set) var selectedID: UUID?

    /// 每个马赛克图层对应一张预先算好的小图。
    /// 绝不在每帧重跑 CoreImage —— 那是上一轮把主线程压垮的同一类错误。
    private(set) var pixelatePreviews: [UUID: CGImage] = [:]

    private var dragStart: CGPoint?
    private var dragCurrent: CGPoint?

    private var moveID: UUID?
    private var moveLastPoint: CGPoint?

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
    var isMoving: Bool { moveID != nil }

    // MARK: - 绘制中的图层

    private var pendingLayer: Layer? {
        guard let tool, let a = dragStart, let b = dragCurrent else { return nil }
        return makeLayer(tool: tool, from: a, to: b)
    }

    /// 交给渲染层的完整列表：已提交的 + 正在拖的；正在输入的文字带一个光标。
    var displayLayers: Layers<CanvasSpace> {
        var result = layers
        if let editingTextID, let index = result.firstIndex(id: editingTextID) {
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
        select(nil)

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
        selectedID = nil
        layers.removeAll()
        pixelatePreviews.removeAll()
    }

    // MARK: - 选中与拖动

    /// 命中测试（画布空间），从最上层往下找。
    /// 线段类按点到线段的距离判定，其余按外接矩形（都带一圈容差，方便点中细线）。
    func layer(at point: CGPoint) -> UUID? {
        let tolerance = 8 * strokeScale
        for layer in layers.elements.reversed() {
            let hit: Bool
            switch layer.kind {
            case .line, .arrow:
                let d = Self.distance(from: point, toSegment: layer.rect.start, layer.rect.end)
                hit = d <= tolerance + layer.lineWidth / 2
            default:
                hit = layer.rect.cg.standardized
                    .insetBy(dx: -tolerance, dy: -tolerance)
                    .contains(point)
            }
            if hit { return layer.id }
        }
        return nil
    }

    /// 返回选中状态是否发生了变化（决定要不要重绘）。
    @discardableResult
    func select(_ id: UUID?) -> Bool {
        guard selectedID != id else { return false }
        selectedID = id
        return true
    }

    func beginMove(id: UUID, at point: CGPoint) {
        selectedID = id
        moveID = id
        moveLastPoint = point
    }

    @discardableResult
    func updateMove(to point: CGPoint) -> Bool {
        guard let moveID, let last = moveLastPoint,
              let index = layers.firstIndex(id: moveID) else { return false }
        layers[index].rect.x += point.x - last.x
        layers[index].rect.y += point.y - last.y
        moveLastPoint = point
        return true
    }

    /// 结束拖动。马赛克的位置变了，预算好的贴片必须按新位置重裁。
    /// - Parameter pixelSource: 和 `endDraw` 的同名参数一致：给画布空间矩形，返回原始像素。
    @discardableResult
    func endMove(pixelSource: (CGRect) -> CGImage?) -> Bool {
        defer {
            moveID = nil
            moveLastPoint = nil
        }
        guard let moveID, let index = layers.firstIndex(id: moveID) else { return false }
        let layer = layers[index]
        if layer.kind == .pixelate {
            pixelatePreviews[layer.id] = pixelSource(layer.rect.cg).flatMap(LayerRenderer.pixelated)
        }
        return true
    }

    /// 删除选中的图层，连带清理它的马赛克贴片。
    @discardableResult
    func deleteSelected() -> Bool {
        guard let id = selectedID else { return false }
        selectedID = nil
        guard layers.firstIndex(id: id) != nil else { return false }
        layers.remove(id: id)
        pixelatePreviews[id] = nil
        return true
    }

    /// 把当前颜色应用到选中的图层（高亮保持半透明）。
    @discardableResult
    func applyColorToSelection() -> Bool {
        guard let selectedID, let index = layers.firstIndex(id: selectedID) else { return false }
        var c = color
        if layers[index].kind == .highlight { c.a = 0.4 }
        layers[index].color = c
        return true
    }

    /// 把当前粗细（和随之派生的字号）应用到选中的图层。
    @discardableResult
    func applyWidthToSelection() -> Bool {
        guard let selectedID, let index = layers.firstIndex(id: selectedID) else { return false }
        layers[index].lineWidth = lineWidth
        layers[index].fontSize = fontSize
        return true
    }

    private nonisolated static func distance(
        from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint
    ) -> Double {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    // MARK: - 文字输入

    func insertText(_ text: String) {
        guard let editingTextID, let index = layers.firstIndex(id: editingTextID) else { return }
        layers[index].text += text
    }

    func deleteBackward() {
        guard let editingTextID,
              let index = layers.firstIndex(id: editingTextID),
              !layers[index].text.isEmpty else { return }
        layers[index].text.removeLast()
    }

    /// 结束输入。空文字图层直接丢弃，避免留下看不见的空壳。
    func endTextEditing() {
        guard let id = editingTextID else { return }
        editingTextID = nil
        if let index = layers.firstIndex(id: id), layers[index].text.isEmpty {
            layers.remove(id: id)
        }
    }

    // MARK: - 撤销

    @discardableResult
    func undo() -> Bool {
        endTextEditing()
        guard let last = layers.removeLast() else { return false }
        pixelatePreviews[last.id] = nil
        if selectedID == last.id { selectedID = nil }
        return true
    }

    // MARK: - 导出

    /// 换算到图像像素空间。桥的实现在 `Layers.projected`，这里只是转发。
    func exportLayers(selection: CGRect, scale: CGFloat) -> Layers<ImageSpace> {
        layers.projected(onto: selection, scale: scale)
    }
}
