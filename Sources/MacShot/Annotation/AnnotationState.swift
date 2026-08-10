import AppKit
import Combine

/// 即时标注的状态机。截图覆盖层和钉图窗口共用同一个实例类型 ——
/// 两处的工具、颜色、粗细、撤销行为因此完全一致。
///
/// 坐标用调用方定义的「画布空间」，唯一约定是**左上原点、Y 向下**，
/// 和 `LayerRenderer` 的假设一致，所以预览和导出能共用同一份绘制代码。
///   · 截图覆盖层：显示器局部、点（不依赖选区原点，选区被拖动也不会让标注错位）
///   · 钉图窗口：  图片像素
@MainActor
final class AnnotationState: ObservableObject {

    // MARK: - 变更发布
    //
    // 状态机**自己**宣告变更。此前它不是 ObservableObject，SwiftUI 察觉不到它变了，
    // 于是编辑器（`EditorView`）在每一处调用后面手写 `annotationTick += 1` 来触发重绘 ——
    // 全文件 24 处，漏掉一处就是「画了没反应」，而且编译器不会提醒。
    // 更要命的是那个计数器是视图的 `@State`：**任何能改标注的子视图都必须够得到它**，
    // 于是工具栏、画布、效果面板、图层面板只能挤在同一个视图里，拆不开。
    //
    // 两个 AppKit 宿主（截图浮层、钉图）不受影响：它们本来就自己 `setNeedsDisplay`，
    // 多一个发布对它们是空操作。
    //
    // **新增会影响渲染的存储属性时，记得挂上同样的 `willSet`。**
    // 用 willSet 而不是 didSet：`objectWillChange` 的契约是「变更**之前**发信号」，
    // 与 @Published 一致。

    private func publishChange() { objectWillChange.send() }

    nonisolated static let palette: [LColor] = [
        LColor(r: 0.98, g: 0.22, b: 0.22, a: 1),   // 红
        LColor(r: 1.00, g: 0.72, b: 0.10, a: 1),   // 橙
        LColor(r: 0.20, g: 0.55, b: 0.98, a: 1),   // 蓝
        LColor(r: 1.00, g: 1.00, b: 1.00, a: 1)    // 白
    ]
    nonisolated static let widths: [Double] = [2, 4, 8]

    /// nil 表示指针模式：拖拽是调整选区，而不是画标注。
    var tool: AnnotationTool? { willSet { publishChange() } }

    /// 「鼠标（指针）」是否被主动选中。截图覆盖层有一个**中性默认态** ——
    /// 确认选区后 tool == nil 且 pointerEngaged == false：没有任何工具高亮，
    /// 拖拽只调整选区，不做图层命中、不做选字；点「鼠标」按钮（或按 V）后
    /// 才进入 tool == nil && pointerEngaged 的完整指针模式（图层可选、Live Text 选字）。
    /// 钉图/编辑器没有中性态概念，默认 true 维持现状。
    var pointerEngaged: Bool = true { willSet { publishChange() } }

    /// 每个工具各记各的样式（键是 `AnnotationTool.id`）。
    /// 旧版本这里是全局的一份 colorIndex/widthIndex，所有工具共用 ——
    /// 拿箭头选了红色粗线，切到文字就是红色粗体。见 `ToolStyle`。
    private var toolStyles: [String: ToolStyle] = [:] { willSet { publishChange() } }

    /// 样式持久化的落盘通道。注入式：生产用 AppSettings.shared，预览/测试用 FakeStyleStore。
    private let styleStore: any StyleStore

    /// 画布空间相对屏幕点的倍率。笔宽和字号按它换算，
    /// 这样不管画布怎么缩放，画出来的线在屏幕上都是同样粗细。
    var strokeScale: Double = 1 { willSet { publishChange() } }

    /// 画布单位到**图像像素**的倍率。测量标注的数值按它换算：
    /// 覆盖层画布是显示器的点（Retina 上 1 点 = 2 像素），钉图/编辑器画布本身就是像素（保持 1）。
    /// 数值在生成图层时烤进 `text`，投影导出后不再重算 —— 预览和成品显示同一个数。
    var pixelScale: Double = 1 { willSet { publishChange() } }

    /// 开启效果那一刻的注入上下文提供者（见 `EffectContext`）：成品图像素宽、
    /// 壳/信息栏结构倍率、真实元数据。三宿主在构造/装载时各设一次，
    /// 值在 `toggleEffect` 那一刻现取（烤入语义）——
    /// 覆盖层的选区宽度、窗口归因都以开关瞬间为准。
    var effectContext: () -> EffectContext = { EffectContext() }

    private(set) var layers = Layers<CanvasSpace>() { willSet { publishChange() } }
    private(set) var editingTextID: UUID? { willSet { publishChange() } }
    /// 输入法合成中的标注文本（marked text），不入撤销栈，仅作预览。
    var markedText: String? { willSet { publishChange() } }

    /// 指针模式下选中的图层。选中后可以拖动、删除、改样式。
    private(set) var selectedID: UUID? { willSet { publishChange() } }

    /// 每个马赛克图层对应一张预先算好的小图。
    /// 绝不在每帧重跑 CoreImage —— 那是上一轮把主线程压垮的同一类错误。
    private(set) var pixelatePreviews: [UUID: CGImage] = [:] { willSet { publishChange() } }

    private var dragStart: CGPoint? { willSet { publishChange() } }
    private var dragCurrent: CGPoint? { willSet { publishChange() } }

    private var moveID: UUID? { willSet { publishChange() } }
    private var moveLastPoint: CGPoint? { willSet { publishChange() } }
    /// beginMove 时的矩形与马赛克贴片。endMove 拿它们记一条可撤销的 move。
    private var moveFromRect: LRect?
    private var moveFromPreview: CGImage?

    /// 拖角缩放的进行时状态。`resizeOriginal` 是 beginResize 时的整层快照 ——
    /// 每帧都从「快照 + 累计位移」重算，不累积浮点误差；endResize 拿它记撤销。
    private var resizeID: UUID? { willSet { publishChange() } }
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

    private var undoStack: [Mutation] = [] { willSet { publishChange() } }
    private var redoStack: [Mutation] = [] { willSet { publishChange() } }

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

    init(styleStore: any StyleStore = AppSettings.shared) {
        self.styleStore = styleStore
        // 先铺描述符声明的默认样式，再用用户存下来的偏好覆盖。
        // 设置页里那两个全局默认（颜色/粗细）作为**首次使用**的种子，
        // 只作用于还没有单独偏好的工具。
        let seedColor = Self.palette.indices.contains(styleStore.defaultColorIndex)
            ? styleStore.defaultColorIndex : 0
        let seedWidth = Self.widths.indices.contains(styleStore.defaultWidthIndex)
            ? styleStore.defaultWidthIndex : 1

        for descriptor in ToolRegistry.descriptors {
            var style = descriptor.defaultStyle
            if descriptor.axes.contains(.color) { style.colorIndex = seedColor }
            if descriptor.axes.contains(.width) { style.widthIndex = seedWidth }
            toolStyles[descriptor.tool.id] = style
        }
        for (id, saved) in styleStore.toolStyles {
            toolStyles[id] = saved
        }
    }

    // MARK: - 当前样式
    //
    // 「当前」指的是**正在用的那个工具**；指针模式下选中了图层时，
    // 指的是那一层对应的工具 —— 点中一个箭头再点色块，改的是箭头的样式。

    /// 样式归属的工具。工具条按它决定显示哪些轴。
    var styleTool: AnnotationTool? {
        if let tool { return tool }
        guard let selectedID, let index = layers.firstIndex(id: selectedID) else { return nil }
        return AnnotationTool(kind: layers[index].kind)
    }

    /// 当前工具声明的样式轴。没有工具（纯指针、未选中）时为空 —— 工具条不摆任何样式控件。
    var styleAxes: [ToolStyleAxis] {
        guard let styleTool else { return [] }
        return ToolRegistry.descriptor(for: styleTool).axes
    }

    var currentStyle: ToolStyle {
        guard let styleTool else { return ToolStyle() }
        return toolStyles[styleTool.id] ?? ToolRegistry.descriptor(for: styleTool).defaultStyle
    }

    func styleIndex(for axis: ToolStyleAxis) -> Int { currentStyle.index(for: axis) }

    /// 改当前工具某根轴的档位，并落盘。返回是否真的变了。
    @discardableResult
    func setStyleIndex(_ index: Int, for axis: ToolStyleAxis) -> Bool {
        guard let styleTool else { return false }
        var style = currentStyle
        guard style.index(for: axis) != index else { return false }
        style.setIndex(index, for: axis)
        toolStyles[styleTool.id] = style
        var dict = styleStore.toolStyles
        dict[styleTool.id] = style
        styleStore.toolStyles = dict
        return true
    }

    var color: LColor {
        let index = currentStyle.colorIndex
        return Self.palette.indices.contains(index) ? Self.palette[index] : Self.palette[0]
    }
    var lineWidth: Double { currentStyle.value(for: .width) * strokeScale }
    var fontSize: Double { currentStyle.value(for: .fontSize) * strokeScale }

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

    /// 交给渲染层的完整列表：已提交的 + 正在拖的；正在输入的文字带一个光标或合成预览。
    var displayLayers: Layers<CanvasSpace> {
        var result = layers
        if let editingTextID, let index = result.firstIndex(id: editingTextID) {
            if let marked = markedText, !marked.isEmpty {
                // 合成中：原文 + 带下划线的合成串（渲染层仍按普通文字画，候选窗口由系统绘制）。
                result[index].text += marked
            } else {
                result[index].text += "|"
            }
        }
        if let pendingLayer {
            result.append(pendingLayer)
        }
        return result
    }

    /// 造层。形体、命中、缩放这些「工具自己的事」全部交给描述符 ——
    /// 状态机只负责把材料凑齐（见 `AnnotationToolDescriptor`）。
    private func makeLayer(tool: AnnotationTool, from a: CGPoint, to b: CGPoint) -> Layer {
        let descriptor = ToolRegistry.descriptor(for: tool)
        // 用**这个工具自己**的样式，而不是当前 styleTool 的 ——
        // 两者通常一致，但选中图层时 styleTool 指向被选中那层的工具。
        let style = toolStyles[tool.id] ?? descriptor.defaultStyle
        let color = Self.palette.indices.contains(style.colorIndex)
            ? Self.palette[style.colorIndex] : Self.palette[0]

        return descriptor.makeLayer(ToolLayerContext(
            from: a,
            to: b,
            style: style,
            color: color,
            strokeScale: strokeScale,
            pixelScale: pixelScale,
            existing: layers.elements
        ))
    }

    // MARK: - 输入

    /// 落笔。点击类工具（文字、序号）当场落层，拖拽类进入拖拽态。
    /// 返回是否需要重绘。
    @discardableResult
    func beginDraw(at point: CGPoint) -> Bool {
        guard let tool else { return false }
        endTextEditing()
        select(nil)

        guard ToolRegistry.descriptor(for: tool).input == .click else {
            dragStart = point
            dragCurrent = point
            return true
        }

        let layer = makeLayer(tool: tool, from: point, to: point)
        layers.append(layer)

        // 文字要接着进编辑态（入栈时机在 endTextEditing）；
        // 其余点击类工具当场记一条 add，撤销一次整层消失。
        if tool == .text {
            editingTextID = layer.id
            editingTextOriginal = nil
        } else {
            record(.add(layer, preview: nil))
        }
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
            pixelatePreviews[layer.id] = pixelSource(r).flatMap { LayerRenderer.pixelated($0, blockScale: layer.blockScale ?? 1) }
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
            pixelatePreviews[layer.id] = pixelSource(layer.rect.cg).flatMap { LayerRenderer.pixelated($0, blockScale: layer.blockScale ?? 1) }
        }
    }

    // MARK: - 选中与拖动

    /// 命中测试（画布空间），从最上层往下找。判定规则各工具自己定
    /// （线段按距离、序号按圆形、其余按外接矩形，都带一圈容差方便点中细线）。
    /// 效果层（`kind.isEffect`）没有画布上的形体，不参与命中，只能通过开关/菜单操作。
    func layer(at point: CGPoint) -> UUID? {
        let tolerance = 8 * strokeScale
        for layer in layers.elements.reversed() where !layer.kind.isEffect {
            guard let descriptor = ToolRegistry.descriptor(for: layer.kind) else { continue }
            if descriptor.hitTest(layer, at: point, tolerance: tolerance) { return layer.id }
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
            pixelatePreviews[layer.id] = pixelSource(layer.rect.cg).flatMap { LayerRenderer.pixelated($0, blockScale: layer.blockScale ?? 1) }
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
        guard let descriptor = ToolRegistry.descriptor(for: original.kind) else { return false }
        layers[index] = descriptor.resize(
            original, handle: handle, delta: delta, pixelScale: pixelScale
        )
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
            pixelatePreviews[resizeID] = pixelSource(layer.rect.cg).flatMap { LayerRenderer.pixelated($0, blockScale: layer.blockScale ?? 1) }
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

    /// 缩到多小算「缩没了」由各工具自己定（线段看长度、文字看字号、
    /// 测量允许单维为 0 的吸附形态）。效果层不参与缩放，一律放行。
    private static func meetsMinimumSize(_ layer: Layer) -> Bool {
        ToolRegistry.descriptor(for: layer.kind)?.meetsMinimumSize(layer) ?? true
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
        // 高亮的透明度是它自己那根轴，不再是写死的 0.4。
        if layers[index].kind == .highlight {
            c.a = currentStyle.value(for: .opacity)
        }
        let before = layers[index]
        layers[index].color = c
        if before != layers[index] {
            record(.style(id: selectedID, before: before, after: layers[index]))
        }
        return true
    }

    /// 把某根样式轴的当前档位应用到选中的图层。
    ///
    /// 「点中一层再点样式」是最直觉的改样式方式，所以每根轴都支持 ——
    /// 唯独 `.blockSize` 例外：马赛克的显示靠预先算好的贴片，重算需要原始像素，
    /// 而工具条控件手上没有像素来源。把取样闭包存进状态机会让「视图 → 状态机 →
    /// 闭包 → 视图」成环，不值得为此冒内存泄漏的风险。改颗粒因此只影响新画的马赛克。
    @discardableResult
    func applyStyleToSelection(_ axis: ToolStyleAxis) -> Bool {
        guard let selectedID, let index = layers.firstIndex(id: selectedID) else { return false }
        let before = layers[index]
        guard let descriptor = Optional(axis.descriptor),
              let apply = descriptor.applyToLayer else { return false }
        let applied = apply(&layers[index], currentStyle, strokeScale)
        guard applied else { return false }
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
    var backdropPresetID: String? { effectText(.backdrop).map { BackdropSpec.parse($0).preset } }

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
    ///
    /// **只换 preset 一个字段**：`text` 里还装着阴影参数，
    /// 整条覆盖成预设名会把它们抹掉（旧实现就是这样，那时 text 里只有预设名）。
    @discardableResult
    func setBackdropPreset(_ presetID: String) -> Bool {
        updateEffect(.backdrop) { text in
            var spec = BackdropSpec.parse(text)
            guard spec.preset != presetID else { return nil }
            spec.preset = presetID
            return spec.json
        }
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

    // 点到线段的距离已经搬到 `ToolGeometry` —— 用它的只剩线段类工具的命中测试。

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
        // 清掉合成态，避免下一次编辑带着上次的拼音残影。
        markedText = nil
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
