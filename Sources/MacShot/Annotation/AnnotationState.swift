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

    /// 「鼠标（指针）」是否被主动选中。截图覆盖层有一个**中性默认态** ——
    /// 确认选区后 tool == nil 且 pointerEngaged == false：没有任何工具高亮，
    /// 拖拽只调整选区，不做图层命中、不做选字；点「鼠标」按钮（或按 V）后
    /// 才进入 tool == nil && pointerEngaged 的完整指针模式（图层可选、Live Text 选字）。
    /// 钉图/编辑器没有中性态概念，默认 true 维持现状。
    var pointerEngaged: Bool = true

    var colorIndex: Int
    var widthIndex: Int

    /// 画布空间相对屏幕点的倍率。笔宽和字号按它换算，
    /// 这样不管画布怎么缩放，画出来的线在屏幕上都是同样粗细。
    var strokeScale: Double = 1

    /// 画布单位到**图像像素**的倍率。测量标注的数值按它换算：
    /// 覆盖层画布是显示器的点（Retina 上 1 点 = 2 像素），钉图/编辑器画布本身就是像素（保持 1）。
    /// 数值在生成图层时烤进 `text`，投影导出后不再重算 —— 预览和成品显示同一个数。
    var pixelScale: Double = 1

    /// 成品图**像素宽**的提供者，水印字号按「图宽 3%」烤入时用：
    /// 覆盖层 = 选区宽 × pixelScale，钉图/编辑器 = 图像像素宽。
    /// nil 时字号只按 14px 下限走。
    var imagePixelWidthProvider: (() -> Double)?

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
    /// beginMove 时的矩形与马赛克贴片。endMove 拿它们记一条可撤销的 move。
    private var moveFromRect: LRect?
    private var moveFromPreview: CGImage?

    /// 拖角缩放的进行时状态。`resizeOriginal` 是 beginResize 时的整层快照 ——
    /// 每帧都从「快照 + 累计位移」重算，不累积浮点误差；endResize 拿它记撤销。
    private var resizeID: UUID?
    private var activeResizeHandle: ResizeHandle?
    private var resizeOriginal: Layer?
    private var resizeStartPoint: CGPoint?
    private var resizeFromPreview: CGImage?

    /// 文字编辑开始时的快照。nil 表示这一层是本次编辑新建的 ——
    /// 结束时非空算 add，被丢弃算「add 的取消」，都不需要 style 记录。
    private var editingTextOriginal: Layer?

    // MARK: - 操作栈

    /// 一次可逆的改动。撤销/重做只回放这些记录，绝不重新计算 ——
    /// 马赛克贴片直接存进记录里，撤销时原样恢复，不依赖任何外部像素源的生命周期。
    private enum Mutation {
        /// 撤销 = 删掉它（连带贴片）；重做 = 连贴片一起加回来。
        case add(Layer, preview: CGImage?)
        /// 撤销 = 按原位插回、恢复贴片。
        case remove(Layer, index: Int, preview: CGImage?)
        case move(id: UUID, from: LRect, to: LRect, oldPreview: CGImage?, newPreview: CGImage?)
        /// 颜色 / 粗细 / 文字内容都算 style：整层快照替换，简单且不会漏字段。
        case style(id: UUID, before: Layer, after: Layer)
    }

    private var undoStack: [Mutation] = []
    private var redoStack: [Mutation] = []

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    /// `setText` 连续针对哪一层在合并撤销记录。任何其它记录入栈都会打断合并。
    private var coalescingTextID: UUID?

    /// 所有写路径的唯一入口：新动作发生后，之前撤销掉的分支就不可再重做。
    private func record(_ mutation: Mutation) {
        coalescingTextID = nil
        undoStack.append(mutation)
        redoStack.removeAll()
    }

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
    var isResizing: Bool { resizeID != nil }

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
        var layer = Layer(
            kind: tool.layerKind,
            rect: LRect(from: a, to: b),
            color: c,
            lineWidth: lineWidth,
            text: "",
            fontSize: fontSize
        )
        if tool == .dimension {
            prepareDimension(&layer)
        }
        return layer
    }

    /// 测量层的整形：拖拽过程中每帧都会经过这里（`pendingLayer` 重建图层）。
    ///   · 近似横/竖的拖拽（薄轴不足 8 像素）吸附成单维 —— 薄轴收拢为 0，
    ///     渲染层据此退化为双箭头线段，只标长度
    ///   · 标签数值按 `pixelScale` 换算成图像像素后烤进 `text`：
    ///     覆盖层画布是点、导出是像素，只有生成时算好才能保证预览和成品显示同一个数
    private func prepareDimension(_ layer: inout Layer) {
        var r = layer.rect.cg.standardized
        if min(r.width, r.height) * pixelScale < 8 {
            r = r.width >= r.height
                ? CGRect(x: r.minX, y: r.midY, width: r.width, height: 0)
                : CGRect(x: r.midX, y: r.minY, width: 0, height: r.height)
        }
        layer.rect = LRect(r)

        let w = Int((r.width * pixelScale).rounded())
        let h = Int((r.height * pixelScale).rounded())
        if r.height == 0 {
            layer.text = "\(w) px"
        } else if r.width == 0 {
            layer.text = "\(h) px"
        } else {
            layer.text = "\(w) × \(h) px"
        }
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
            editingTextOriginal = nil   // 新建的层，入栈时机在 endTextEditing
            return true
        }

        // 序号也是点击落点，但不进入文字编辑态：直接落一个带编号的层，
        // 一条 add 记录，撤销一次整层消失。
        if tool == .counter {
            let diameter = max(28 * strokeScale, fontSize * 1.4)
            var layer = makeLayer(tool: .counter, from: point, to: point)
            // 点击处是圆心，rect 存外接矩形。
            layer.rect = LRect(CGRect(
                x: point.x - diameter / 2,
                y: point.y - diameter / 2,
                width: diameter,
                height: diameter
            ))
            layer.text = String(nextCounterNumber)
            layers.append(layer)
            record(.add(layer, preview: nil))
            return true
        }

        dragStart = point
        dragCurrent = point
        return true
    }

    /// 下一个序号：扫现有序号层取最大值 +1。
    /// 刻意不在删除时重排 —— 删掉中间某个序号后，后续编号保持不变。
    private var nextCounterNumber: Int {
        (layers.elements
            .filter { $0.kind == .counter }
            .compactMap { Int($0.text) }
            .max() ?? 0) + 1
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
        // 裁剪同时只允许存在一个：旧的记成可撤销的删除，再落新的。
        if layer.kind == .crop {
            while let index = layers.elements.firstIndex(where: { $0.kind == .crop }) {
                let old = layers[index]
                record(.remove(old, index: index, preview: nil))
                layers.remove(id: old.id)
            }
        }
        layers.append(layer)
        record(.add(layer, preview: pixelatePreviews[layer.id]))
        return true
    }

    /// 丢弃全部标注，回到干净状态。撤销历史一并清空 —— 不做跨清空的持久撤销。
    func clear() {
        endTextEditing()
        selectedID = nil
        dragStart = nil
        dragCurrent = nil
        moveID = nil
        moveLastPoint = nil
        moveFromRect = nil
        moveFromPreview = nil
        resizeID = nil
        activeResizeHandle = nil
        resizeOriginal = nil
        resizeStartPoint = nil
        resizeFromPreview = nil
        layers.removeAll()
        pixelatePreviews.removeAll()
        undoStack.removeAll()
        redoStack.removeAll()
    }

    /// 载入已有图层继续编辑（图库编辑器专用；覆盖层/钉图都从空白开始，不需要它）。
    ///
    /// **只适用于画布空间就是图像像素的画布** —— 内部按恒等变换收进 `CanvasSpace`，
    /// 导出时再经 `projected(onto: .zero, scale: 1)` 恒等换回。
    /// 载入即换底，撤销栈一并清空。
    /// - Parameter pixelSource: 与 `endDraw` 的同名参数一致：给画布空间矩形返回原始像素，
    ///   用来为载入的马赛克图层重建预览贴片。
    func load(_ source: Layers<ImageSpace>, pixelSource: (CGRect) -> CGImage?) {
        clear()
        layers = Layers<CanvasSpace>(source.elements)
        for layer in layers.elements where layer.kind == .pixelate {
            pixelatePreviews[layer.id] = pixelSource(layer.rect.cg).flatMap(LayerRenderer.pixelated)
        }
    }

    // MARK: - 选中与拖动

    /// 命中测试（画布空间），从最上层往下找。
    /// 线段类按点到线段的距离判定，其余按外接矩形（都带一圈容差，方便点中细线）。
    /// 美化 / 水印 / 外壳 / 捕获信息层没有画布上的形体，不参与命中，只能通过开关/菜单操作。
    func layer(at point: CGPoint) -> UUID? {
        let tolerance = 8 * strokeScale
        for layer in layers.elements.reversed()
        where layer.kind != .backdrop && layer.kind != .watermark && layer.kind != .frame
            && layer.kind != .captureInfo {
            let hit: Bool
            switch layer.kind {
            case .line, .arrow:
                let d = Self.distance(from: point, toSegment: layer.rect.start, layer.rect.end)
                hit = d <= tolerance + layer.lineWidth / 2
            case .counter:
                // 徽章是圆的，按圆形区域命中，别让四个角白占位置。
                let r = layer.rect.cg
                hit = hypot(point.x - r.midX, point.y - r.midY) <= r.width / 2 + tolerance
            default:
                // text 的 rect 只存锚点，按量出的文字范围命中（与选中框/控制点一致）；
                // 其余 kind `handleBounds` 就是 rect 本身。
                hit = layer.handleBounds
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
        // 换了选中对象，文字替换的撤销合并就该重新开一条记录。
        coalescingTextID = nil
        return true
    }

    func beginMove(id: UUID, at point: CGPoint) {
        selectedID = id
        moveID = id
        moveLastPoint = point
        if let index = layers.firstIndex(id: id) {
            moveFromRect = layers[index].rect
            moveFromPreview = pixelatePreviews[id]
        }
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
            moveFromRect = nil
            moveFromPreview = nil
        }
        guard let moveID, let index = layers.firstIndex(id: moveID) else { return false }
        let layer = layers[index]
        if layer.kind == .pixelate {
            pixelatePreviews[layer.id] = pixelSource(layer.rect.cg).flatMap(LayerRenderer.pixelated)
        }
        // 原地点了一下没有位移，不算一次操作。
        if let from = moveFromRect, from != layer.rect {
            record(.move(
                id: moveID,
                from: from,
                to: layer.rect,
                oldPreview: moveFromPreview,
                newPreview: pixelatePreviews[layer.id]
            ))
        }
        return true
    }

    // MARK: - 选中图层的拖角缩放

    /// 命中选中图层的缩放控制点（画布空间）。只对 `selectedID` 生效 ——
    /// 控制点只画在选中层上，未选中的层点到的是图层本体（走 beginMove）。
    /// 热区随 `strokeScale` 缩放，屏幕上恒定约 ±8pt。
    func resizeHandle(at point: CGPoint) -> ResizeHandle? {
        guard let selectedID, let index = layers.firstIndex(id: selectedID) else { return nil }
        let layer = layers[index]
        let radius = 8 * strokeScale
        for handle in ResizeHandle.handles(for: layer.kind) {
            let center = handle.location(of: layer)
            if abs(point.x - center.x) <= radius, abs(point.y - center.y) <= radius {
                return handle
            }
        }
        return nil
    }

    func beginResize(handle: ResizeHandle, at point: CGPoint) {
        guard let selectedID, let index = layers.firstIndex(id: selectedID) else { return }
        resizeID = selectedID
        activeResizeHandle = handle
        resizeOriginal = layers[index]
        resizeStartPoint = point
        resizeFromPreview = pixelatePreviews[selectedID]
    }

    /// 按 kind 的缩放语义，每帧从 beginResize 快照重算：
    ///   · line / arrow：只动被拖的那一端，负宽高合法（standardize 会把箭头方向弄反）
    ///   · counter：保持圆形 —— 拖角取 max(w, h)，拖边取被拖的那一维，对侧锚定不动
    ///   · text：rect 只存锚点，按量出的文字范围缩放，fontSize 随高度比例走
    ///   · dimension：改完 rect 重烤标签（`prepareDimension`，像素数值按新尺寸重算）
    ///   · 其余矩形类：直接改 rect
    @discardableResult
    func updateResize(to point: CGPoint) -> Bool {
        guard let resizeID,
              let handle = activeResizeHandle,
              let original = resizeOriginal,
              let start = resizeStartPoint,
              let index = layers.firstIndex(id: resizeID) else { return false }

        let delta = CGPoint(x: point.x - start.x, y: point.y - start.y)
        var layer = original

        switch original.kind {
        case .line, .arrow:
            if handle == .topLeft {
                layer.rect.x = original.rect.x + delta.x
                layer.rect.y = original.rect.y + delta.y
                layer.rect.w = original.rect.w - delta.x
                layer.rect.h = original.rect.h - delta.y
            } else {
                layer.rect.w = original.rect.w + delta.x
                layer.rect.h = original.rect.h + delta.y
            }

        case .counter:
            layer.rect = LRect(Self.counterSquare(
                handle: handle, delta: delta, original: original.rect.cg
            ))

        case .text:
            let bounds = original.handleBounds
            let resized = handle.apply(delta: delta, to: bounds)
            layer.rect.x = resized.minX
            layer.rect.y = resized.minY
            if bounds.height > 0 {
                layer.fontSize = max(4, original.fontSize * resized.height / bounds.height)
            }

        case .dimension:
            layer.rect = LRect(handle.apply(delta: delta, to: original.rect.cg))
            prepareDimension(&layer)

        default:
            layer.rect = LRect(handle.apply(delta: delta, to: original.rect.cg))
        }

        layers[index] = layer
        return true
    }

    /// 结束缩放。缩没了（小于最小尺寸）整层恢复原样、不入栈；
    /// 马赛克按新矩形重裁贴片（同 `endMove`）。撤销记录：
    /// 马赛克走 `.move`（它带贴片快照，style 不带），其余整层快照走 `.style`。
    /// - Parameter pixelSource: 和 `endDraw` 的同名参数一致。
    @discardableResult
    func endResize(pixelSource: (CGRect) -> CGImage?) -> Bool {
        defer {
            resizeID = nil
            activeResizeHandle = nil
            resizeOriginal = nil
            resizeStartPoint = nil
            resizeFromPreview = nil
        }
        guard let resizeID,
              let original = resizeOriginal,
              let index = layers.firstIndex(id: resizeID) else { return false }
        let layer = layers[index]

        if !Self.meetsMinimumSize(layer) {
            layers[index] = original
            if original.kind == .pixelate { pixelatePreviews[resizeID] = resizeFromPreview }
            return true
        }
        // 原地点了一下没有变化，不算一次操作。
        guard layer != original else { return true }

        if layer.kind == .pixelate {
            pixelatePreviews[resizeID] = pixelSource(layer.rect.cg).flatMap(LayerRenderer.pixelated)
            record(.move(
                id: resizeID,
                from: original.rect,
                to: layer.rect,
                oldPreview: resizeFromPreview,
                newPreview: pixelatePreviews[resizeID]
            ))
        } else {
            record(.style(id: resizeID, before: original, after: layer))
        }
        return true
    }

    /// 最小尺寸（画布单位）。线段类只要长度别缩没，dimension 允许单维为 0（吸附形态）。
    private nonisolated static func meetsMinimumSize(_ layer: Layer) -> Bool {
        let minSide = 4.0
        switch layer.kind {
        case .line, .arrow, .dimension:
            return max(abs(layer.rect.w), abs(layer.rect.h)) >= minSide
        case .text:
            return layer.fontSize >= 4
        default:
            let r = layer.rect.cg
            return r.width >= minSide && r.height >= minSide
        }
    }

    /// 序号徽章保持圆形：直径 d 拖角取 max(w, h)、拖边取被拖的那一维；
    /// 被拖控制点的对侧保持不动（拖边时另一轴居中锚定）。
    private nonisolated static func counterSquare(
        handle: ResizeHandle, delta: CGPoint, original: CGRect
    ) -> CGRect {
        let applied = handle.apply(delta: delta, to: original)
        let d: CGFloat
        switch handle {
        case .top, .bottom: d = applied.height
        case .left, .right: d = applied.width
        default:            d = max(applied.width, applied.height)
        }

        let minX: CGFloat
        switch handle {
        case .topLeft, .left, .bottomLeft:     minX = original.maxX - d
        case .topRight, .right, .bottomRight:  minX = original.minX
        default:                               minX = original.midX - d / 2
        }
        let minY: CGFloat
        switch handle {
        case .topLeft, .top, .topRight:        minY = original.minY
        case .bottomLeft, .bottom, .bottomRight: minY = original.maxY - d
        default:                               minY = original.midY - d / 2
        }
        return CGRect(x: minX, y: minY, width: d, height: d)
    }

    /// 删除选中的图层，连带清理它的马赛克贴片。
    @discardableResult
    func deleteSelected() -> Bool {
        guard let id = selectedID else { return false }
        selectedID = nil
        guard let index = layers.firstIndex(id: id) else { return false }
        record(.remove(layers[index], index: index, preview: pixelatePreviews[id]))
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
        let before = layers[index]
        layers[index].color = c
        if before != layers[index] {
            record(.style(id: selectedID, before: before, after: layers[index]))
        }
        return true
    }

    /// 把当前粗细（和随之派生的字号）应用到选中的图层。
    @discardableResult
    func applyWidthToSelection() -> Bool {
        guard let selectedID, let index = layers.firstIndex(id: selectedID) else { return false }
        let before = layers[index]
        layers[index].lineWidth = lineWidth
        layers[index].fontSize = fontSize
        if before != layers[index] {
            record(.style(id: selectedID, before: before, after: layers[index]))
        }
        return true
    }

    // MARK: - 美化层（backdrop）

    /// 当前是否已开启美化。工具条开关的选中态看它。
    var hasBackdrop: Bool {
        layers.elements.contains { $0.kind == .backdrop }
    }

    /// 当前美化层的背景预设名；未开启时为 nil。
    var backdropPresetID: String? {
        layers.elements.last { $0.kind == .backdrop }?.text
    }

    /// 美化开关。backdrop 不是拖出来的图层，只有加/删两种操作：
    /// 没有则加一层默认预设，有则全部删掉。都走 `record` 保持可撤销。
    /// 同时只保留一层 —— 加之前先清干净（正常情况下最多一层）。
    @discardableResult
    func toggleBackdrop() -> Bool {
        endTextEditing()
        if hasBackdrop {
            while let index = layers.elements.firstIndex(where: { $0.kind == .backdrop }) {
                let old = layers[index]
                record(.remove(old, index: index, preview: nil))
                layers.remove(id: old.id)
                if selectedID == old.id { selectedID = nil }
            }
            return false
        }
        var layer = Layer(kind: .backdrop, rect: LRect(x: 0, y: 0, w: 0, h: 0))
        layer.lineWidth = 48            // 复用字段：四周留白 padding
        layer.fontSize = 12             // 复用字段：内容圆角半径
        layer.text = BackdropPreset.default.rawValue
        layers.append(layer)
        record(.add(layer, preview: nil))
        return true
    }

    /// 替换美化层的背景预设，记一条 style 撤销记录。未开启时不做事。
    @discardableResult
    func setBackdropPreset(_ presetID: String) -> Bool {
        guard let index = layers.elements.firstIndex(where: { $0.kind == .backdrop }),
              layers[index].text != presetID else { return false }
        let before = layers[index]
        layers[index].text = presetID
        record(.style(id: before.id, before: before, after: layers[index]))
        return true
    }

    // MARK: - 水印（watermark）

    /// 当前是否已有水印。工具条开关的选中态看它。
    var hasWatermark: Bool {
        layers.elements.contains { $0.kind == .watermark }
    }

    /// 当前水印的摆放模式；未开启时为 nil。
    var watermarkMode: WatermarkMode? {
        layers.elements.last { $0.kind == .watermark }
            .flatMap { WatermarkSpec.decode($0.text)?.mode }
    }

    /// 水印开关。和 backdrop 一样只有加/删两种操作，都走 `record` 保持可撤销；
    /// 同时只保留一层 —— 加之前先清干净。
    ///
    /// 字号按成品图宽 3%（不小于 14px）烤成图像像素，再反除 `pixelScale`
    /// 换到画布单位；描边同理（1 像素 → 1/pixelScale 画布单位）。
    /// 投影（×pixelScale）后恰好回到烤定的像素值 —— 预览画的和导出画的
    /// 因此是同一个大小，思路与测量标注把数值烤进 `text` 一致。
    @discardableResult
    func toggleWatermark(text: String, mode: WatermarkMode, alpha: Double) -> Bool {
        endTextEditing()
        if hasWatermark {
            while let index = layers.elements.firstIndex(where: { $0.kind == .watermark }) {
                let old = layers[index]
                record(.remove(old, index: index, preview: nil))
                layers.remove(id: old.id)
                if selectedID == old.id { selectedID = nil }
            }
            return false
        }
        var layer = WatermarkSpec.makeLayer(
            text: text,
            mode: mode,
            alpha: alpha,
            imagePixelWidth: imagePixelWidthProvider?() ?? 0
        )
        layer.fontSize /= pixelScale
        layer.lineWidth /= pixelScale
        layers.append(layer)
        record(.add(layer, preview: nil))
        return true
    }

    /// 替换水印的摆放模式，记一条 style 撤销记录。未开启时不做事。
    @discardableResult
    func setWatermarkMode(_ mode: WatermarkMode) -> Bool {
        guard let index = layers.elements.firstIndex(where: { $0.kind == .watermark }),
              var spec = WatermarkSpec.decode(layers[index].text),
              spec.mode != mode else { return false }
        let before = layers[index]
        spec.mode = mode
        layers[index].text = spec.encoded
        record(.style(id: before.id, before: before, after: layers[index]))
        return true
    }

    // MARK: - 外壳层（frame，带壳截图）

    /// 壳结构尺寸（标题栏高、红绿灯直径、圆角）的倍率，开壳时烤进 `lineWidth`。
    /// 语义是「每**视觉点**对应多少画布单位」，投影到图像像素时随 scale 一起放大：
    ///   · 覆盖层画布是显示器的点 —— 保持 1，投影乘 snapshot.scale 后正好是 Retina 倍率
    ///   · 编辑器/钉图画布已是图像像素（投影恒等）—— 注入 shot.scale，
    ///     2x 图上的壳和 1x 图视觉大小一致，线条落在整像素上不发虚
    var frameScale: Double = 1

    /// 开壳时自动烤进参数 JSON 的真实元数据。竞品的带壳都是空壳 ——
    /// 「标题栏是真实窗口标题、地址栏是真实网址」是元数据库独有的卖点。
    ///   · 覆盖层：确认选区时的窗口归因（URL 是落库后异步回填的，此刻还没有 → 留空）
    ///   · 编辑器/钉图：shot.windowTitle / shot.sourceURL
    var frameDefaultTitle: String?
    var frameDefaultURL: String?

    /// 当前是否已套壳。工具条开关的选中态看它。
    var hasFrame: Bool {
        layers.elements.contains { $0.kind == .frame }
    }

    /// 当前壳的样式；未开启时为 nil。
    var frameStyle: FrameSpec.Style? {
        layers.elements.last { $0.kind == .frame }.map { FrameSpec.parse($0.text).style }
    }

    /// 套壳开关。和 backdrop 同一套语义：只有加/删两种操作，同时只保留一层，
    /// 都走 `record` 保持可撤销。默认 macos 壳，标题/网址从元数据自动填。
    @discardableResult
    func toggleFrame() -> Bool {
        endTextEditing()
        if hasFrame {
            while let index = layers.elements.firstIndex(where: { $0.kind == .frame }) {
                let old = layers[index]
                record(.remove(old, index: index, preview: nil))
                layers.remove(id: old.id)
                if selectedID == old.id { selectedID = nil }
            }
            return false
        }
        var layer = Layer(kind: .frame, rect: LRect(x: 0, y: 0, w: 0, h: 0))
        layer.lineWidth = frameScale    // 复用字段：壳的结构尺寸倍率（见 frameScale）
        var spec = FrameSpec()
        spec.title = frameDefaultTitle ?? ""
        spec.url = frameDefaultURL ?? ""
        layer.text = spec.json
        layers.append(layer)
        record(.add(layer, preview: nil))
        return true
    }

    /// 切换壳样式（macOS 窗口 / 浏览器），记一条 style 撤销记录。未开壳时不做事。
    @discardableResult
    func setFrameStyle(_ style: FrameSpec.Style) -> Bool {
        guard let index = layers.elements.firstIndex(where: { $0.kind == .frame }) else {
            return false
        }
        var spec = FrameSpec.parse(layers[index].text)
        guard spec.style != style else { return false }
        spec.style = style
        let before = layers[index]
        layers[index].text = spec.json
        record(.style(id: before.id, before: before, after: layers[index]))
        return true
    }

    // MARK: - 捕获信息层（captureInfo）

    /// 开启效果时烤入参数 JSON 的真实元数据默认值。App 名+版本（如 "Safari 17.4"），
    /// 与 frameDefaultTitle/URL 同一套注入机制、三处注入点同一时机补：
    ///   · 覆盖层：激活工具条控件前从 confirmedWindow 取（URL 还没异步回填 → 留空）
    ///   · 编辑器/钉图：shot.appName + shot.appVersion
    /// 网址直接复用 `frameDefaultURL` —— 同一时机、同一来源，没必要存两份。
    var captureInfoDefaultApp: String?

    /// 捕获时刻。编辑器/钉图注入 shot.capturedAt；覆盖层不注入（nil）——
    /// 截图那一刻就是当下，开启时取 `Date()`。
    var captureInfoDefaultDate: Date?

    /// 信息栏日期的固定排版（本地时区）。烤入后是纯文本，历史成品不随时区漂移。
    private static let captureInfoDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    /// 当前是否已开启捕获信息。工具条开关的选中态看它。
    var hasCaptureInfo: Bool {
        layers.elements.contains { $0.kind == .captureInfo }
    }

    /// 当前勾选要显示的字段；未开启时为 nil。
    var captureInfoFields: [CaptureInfoSpec.Field]? {
        layers.elements.last { $0.kind == .captureInfo }
            .map { CaptureInfoSpec.parse($0.text).fields }
    }

    /// 捕获信息开关。和 backdrop 同一套语义：只有加/删两种操作，同时只保留一层，
    /// 都走 `record` 保持可撤销。元数据（App 名+版本 / 网址 / 日期）在这一刻
    /// 从注入的默认值烤进参数 JSON —— 之后图层自带数据，导出不再回查。
    @discardableResult
    func toggleCaptureInfo(fields: [CaptureInfoSpec.Field] = CaptureInfoSpec.Field.allCases) -> Bool {
        endTextEditing()
        if hasCaptureInfo {
            while let index = layers.elements.firstIndex(where: { $0.kind == .captureInfo }) {
                let old = layers[index]
                record(.remove(old, index: index, preview: nil))
                layers.remove(id: old.id)
                if selectedID == old.id { selectedID = nil }
            }
            return false
        }
        var layer = Layer(kind: .captureInfo, rect: LRect(x: 0, y: 0, w: 0, h: 0))
        layer.lineWidth = frameScale    // 复用字段：信息栏结构尺寸倍率（语义同 frameScale）
        var spec = CaptureInfoSpec()
        spec.fields = fields
        spec.app = captureInfoDefaultApp ?? ""
        spec.url = frameDefaultURL ?? ""
        spec.date = Self.captureInfoDateFormatter.string(
            from: captureInfoDefaultDate ?? Date()
        )
        layer.text = spec.json
        layers.append(layer)
        record(.add(layer, preview: nil))
        return true
    }

    /// 替换勾选字段，记一条 style 撤销记录。烤入的元数据值不动，只改显示哪些。
    /// 未开启时不做事。
    @discardableResult
    func setCaptureInfoFields(_ fields: [CaptureInfoSpec.Field]) -> Bool {
        guard let index = layers.elements.firstIndex(where: { $0.kind == .captureInfo }) else {
            return false
        }
        var spec = CaptureInfoSpec.parse(layers[index].text)
        guard spec.fields != fields else { return false }
        spec.fields = fields
        let before = layers[index]
        layers[index].text = spec.json
        record(.style(id: before.id, before: before, after: layers[index]))
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

    /// 整段替换某一层的文字。图库编辑器的文本框走这里 ——
    /// 覆盖层/钉图是逐键输入（`insertText`），编辑器是绑定一个完整字符串。
    ///
    /// 针对同一层的连续替换合并成一条 style 记录：撤销一次回到编辑前，
    /// 而不是逐键回退出几十条历史。
    func setText(id: UUID, _ text: String) {
        guard let index = layers.firstIndex(id: id), layers[index].text != text else { return }
        let before = layers[index]
        layers[index].text = text

        if coalescingTextID == id,
           case .style(let sid, let original, _)? = undoStack.last, sid == id {
            undoStack[undoStack.count - 1] = .style(id: id, before: original, after: layers[index])
        } else {
            record(.style(id: id, before: before, after: layers[index]))
            coalescingTextID = id
        }
    }

    /// 结束输入。空文字图层直接丢弃，避免留下看不见的空壳。
    /// 入栈时机在这里而不是落点时：新建层写出了内容算 add，
    /// 空着丢弃算「add 的取消」不入栈；已有层内容变了算 style。
    func endTextEditing() {
        guard let id = editingTextID else { return }
        editingTextID = nil
        let original = editingTextOriginal
        editingTextOriginal = nil

        guard let index = layers.firstIndex(id: id) else { return }
        let layer = layers[index]

        if layer.text.isEmpty {
            layers.remove(id: id)
            if let original {
                record(.remove(original, index: index, preview: nil))
            }
            return
        }
        if let original {
            if original != layer {
                record(.style(id: id, before: original, after: layer))
            }
        } else {
            record(.add(layer, preview: nil))
        }
    }

    // MARK: - 撤销 / 重做

    /// 返回是否真的发生了变化，调用方据此决定要不要重绘和落库。
    @discardableResult
    func undo() -> Bool {
        endTextEditing()
        coalescingTextID = nil
        guard let mutation = undoStack.popLast() else { return false }
        revert(mutation)
        redoStack.append(mutation)
        return true
    }

    @discardableResult
    func redo() -> Bool {
        // 不结束文字编辑：endTextEditing 可能入栈新操作并清空 redoStack，
        // 那样这里就会「先毁掉再来重做」。正在输入时直接视为无事可做。
        guard editingTextID == nil, let mutation = redoStack.popLast() else { return false }
        coalescingTextID = nil
        apply(mutation)
        undoStack.append(mutation)
        return true
    }

    /// 撤销一条记录：把它对图层与马赛克贴片的影响原样倒回去。
    private func revert(_ mutation: Mutation) {
        switch mutation {
        case .add(let layer, _):
            layers.remove(id: layer.id)
            pixelatePreviews[layer.id] = nil
            if selectedID == layer.id { selectedID = nil }

        case .remove(let layer, let index, let preview):
            layers.insert(layer, at: index)
            pixelatePreviews[layer.id] = preview
            selectedID = layer.id

        case .move(let id, let from, _, let oldPreview, _):
            guard let index = layers.firstIndex(id: id) else { return }
            layers[index].rect = from
            if layers[index].kind == .pixelate { pixelatePreviews[id] = oldPreview }
            selectedID = id

        case .style(let id, let before, _):
            guard let index = layers.firstIndex(id: id) else { return }
            layers[index] = before
        }
    }

    /// 重做一条记录：和首次执行时的效果完全一致。
    private func apply(_ mutation: Mutation) {
        switch mutation {
        case .add(let layer, let preview):
            layers.append(layer)
            pixelatePreviews[layer.id] = preview

        case .remove(let layer, _, _):
            layers.remove(id: layer.id)
            pixelatePreviews[layer.id] = nil
            if selectedID == layer.id { selectedID = nil }

        case .move(let id, _, let to, _, let newPreview):
            guard let index = layers.firstIndex(id: id) else { return }
            layers[index].rect = to
            if layers[index].kind == .pixelate { pixelatePreviews[id] = newPreview }
            selectedID = id

        case .style(let id, _, let after):
            guard let index = layers.firstIndex(id: id) else { return }
            layers[index] = after
        }
    }

    // MARK: - 导出

    /// 换算到图像像素空间。桥的实现在 `Layers.projected`，这里只是转发。
    func exportLayers(selection: CGRect, scale: CGFloat) -> Layers<ImageSpace> {
        layers.projected(onto: selection, scale: scale)
    }
}
