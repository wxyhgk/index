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

    /// 开启效果那一刻的注入上下文提供者（见 `EffectContext`）：成品图像素宽、
    /// 壳/信息栏结构倍率、真实元数据。三宿主在构造/装载时各设一次，
    /// 值在 `toggleEffect` 那一刻现取（烤入语义）——
    /// 覆盖层的选区宽度、窗口归因都以开关瞬间为准。
    var effectContext: () -> EffectContext = { EffectContext() }

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
    /// 效果层（`kind.isEffect`）没有画布上的形体，不参与命中，只能通过开关/菜单操作。
    func layer(at point: CGPoint) -> UUID? {
        let tolerance = 8 * strokeScale
        for layer in layers.elements.reversed() where !layer.kind.isEffect {
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

    // MARK: - 效果层（watermark / captureInfo / frame / backdrop）

    /// 某效果当前是否开启。工具条开关 / 效果面板的选中态看它。
    func hasEffect(_ kind: Layer.Kind) -> Bool {
        layers.elements.contains { $0.kind == kind }
    }

    /// 效果开关。效果层不是拖出来的图层，只有加/删两种操作：
    /// 没有则按描述符（`EffectRegistry`）造一层，参数与元数据在这一刻从
    /// `effectContext` 烤入；有则全部删掉。都走 `record` 保持可撤销；
    /// 同时只保留一层 —— 加之前先清干净（正常情况下最多一层）。
    @discardableResult
    func toggleEffect(_ kind: Layer.Kind) -> Bool {
        guard let descriptor = EffectRegistry.descriptor(for: kind) else { return false }
        endTextEditing()
        if hasEffect(kind) {
            while let index = layers.elements.firstIndex(where: { $0.kind == kind }) {
                let old = layers[index]
                record(.remove(old, index: index, preview: nil))
                layers.remove(id: old.id)
                if selectedID == old.id { selectedID = nil }
            }
            return false
        }
        var context = effectContext()
        context.pixelScale = pixelScale   // 渲染标度由状态机补充，宿主不用管。
        let layer = descriptor.makeLayer(context)
        layers.append(layer)
        record(.add(layer, preview: nil))
        return true
    }

    /// 某效果层当前的参数串（`Layer.text`）；未开启时 nil。
    private func effectText(_ kind: Layer.Kind) -> String? {
        layers.elements.last { $0.kind == kind }?.text
    }

    /// 替换某效果层的参数串，记一条 style 撤销记录。
    /// `transform` 拿旧参数串返回新的；返回 nil 表示无变化，不入栈。
    /// 未开启该效果时不做事。
    private func updateEffect(_ kind: Layer.Kind, transform: (String) -> String?) -> Bool {
        guard let index = layers.elements.firstIndex(where: { $0.kind == kind }),
              let newText = transform(layers[index].text),
              newText != layers[index].text else { return false }
        let before = layers[index]
        layers[index].text = newText
        record(.style(id: before.id, before: before, after: layers[index]))
        return true
    }

    // MARK: 效果参数的类型化读写（都是 effectText / updateEffect 的一行封装）

    /// 当前美化层的背景预设名；未开启时为 nil。
    var backdropPresetID: String? { effectText(.backdrop) }

    /// 当前水印的摆放模式；未开启时为 nil。
    var watermarkMode: WatermarkMode? {
        effectText(.watermark).flatMap { WatermarkSpec.decode($0)?.mode }
    }

    /// 当前壳的样式；未开启时为 nil。
    var frameStyle: FrameSpec.Style? {
        effectText(.frame).map { FrameSpec.parse($0).style }
    }

    /// 当前勾选要显示的字段；未开启时为 nil。
    var captureInfoFields: [CaptureInfoSpec.Field]? {
        effectText(.captureInfo).map { CaptureInfoSpec.parse($0).fields }
    }

    /// 替换美化层的背景预设。
    @discardableResult
    func setBackdropPreset(_ presetID: String) -> Bool {
        updateEffect(.backdrop) { $0 == presetID ? nil : presetID }
    }

    /// 替换水印的摆放模式。
    @discardableResult
    func setWatermarkMode(_ mode: WatermarkMode) -> Bool {
        updateEffect(.watermark) { text in
            guard var spec = WatermarkSpec.decode(text), spec.mode != mode else { return nil }
            spec.mode = mode
            return spec.encoded
        }
    }

    /// 切换壳样式（macOS 窗口 / 浏览器）。
    @discardableResult
    func setFrameStyle(_ style: FrameSpec.Style) -> Bool {
        updateEffect(.frame) { text in
            var spec = FrameSpec.parse(text)
            guard spec.style != style else { return nil }
            spec.style = style
            return spec.json
        }
    }

    /// 替换勾选字段。烤入的元数据值不动，只改显示哪些。
    @discardableResult
    func setCaptureInfoFields(_ fields: [CaptureInfoSpec.Field]) -> Bool {
        updateEffect(.captureInfo) { text in
            var spec = CaptureInfoSpec.parse(text)
            guard spec.fields != fields else { return nil }
            spec.fields = fields
            return spec.json
        }
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
