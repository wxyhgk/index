import AppKit

// MARK: - 工具契约
//
// 在此之前，「一个标注工具」这个概念是散在十个文件里的：
//   造层与落笔方式、命中测试、缩放语义、最小尺寸  → AnnotationState（973 行）
//   控制点集合                                    → ResizeHandle
//   快捷键                                        → AnnotationTool 的一张表
//   常驻工具条与否                                → BuiltinControls 的一个数组
//   样式轴与默认样式                              → ToolStyle 里的 ToolRegistry
//   绘制                                          → LayerRenderer（1064 行）
// 每处都是一个 switch。git 历史里 AnnotationState ↔ BuiltinControls 共现 84%、
// ↔ LayerRenderer 83% —— 加一个工具必然同时改这几个大文件，两个人并行就会撞车。
//
// 这里把「一个工具是什么」收敛成一份契约 + 一个登记处，与 `CaptureAction`、
// `GalleryDestination` 同一路子。绘制仍在 LayerRenderer（见文件末尾的说明）。

/// 拖动起点命中了图层的哪个区域。
enum LayerMoveTarget {
    /// 源区域（layer.rect 本体）。
    case source
    /// 特殊区域（如放大镜的 display 显示区域）。
    case specialRegion
}

/// 工具落笔的方式。
enum ToolInput {
    /// 拖出形体：矩形、椭圆、箭头、线、马赛克…
    case drag
    /// 点一下就落一层：文字、序号。
    case click
    /// 跟手画路径：自由画笔。
    case stroke
}

/// 造一个新图层时能拿到的全部材料。
///
/// 刻意是个值类型的入参包而不是把 `AnnotationState` 传进来 ——
/// 描述符不该认识状态机，否则「工具」这个概念又会长回去。
struct ToolLayerContext {
    /// 拖拽起点 / 点击落点。
    let from: CGPoint
    /// 拖拽终点。点击类工具与 `from` 相同。
    let to: CGPoint
    /// **这个工具自己**的样式，不是当前 styleTool 的 ——
    /// 选中某层时 styleTool 指向被选中那层的工具，两者会不一致。
    let style: ToolStyle
    /// 调色板里选出的颜色。透明度由 `.opacity` 轴再压一次（在默认实现里）。
    let color: LColor
    /// 画布空间相对屏幕点的倍率。笔宽字号按它换算。
    let strokeScale: Double
    /// 画布单位到图像像素的倍率。测量层烤数值要用。
    let pixelScale: Double
    /// 画布上已有的图层。序号取下一个编号要用。
    let existing: [Layer]
    /// 自由画笔的路径点（画布空间）。非画笔工具为空。
    var strokePoints: [CGPoint] = []
}

/// 一个标注工具的完整契约。
///
/// 加一个工具 = 新写一个实现 + 在 `BuiltinTools.all` 里加一行。
/// **不需要**改 `AnnotationState`、`ResizeHandle`、`BuiltinControls`、快捷键表。
///
/// 刻意**不**绑主线程：描述符是无状态的值类型、方法都是纯函数，
/// 而渲染器（`AnnotationRenderer` / `LayerRenderer`）是 nonisolated 的，
/// 绑上去会逼着渲染路径一起搬到主线程。`Sendable` 由此而来。
protocol AnnotationToolDescriptor: Sendable {

    /// 身份，同时决定落下来的 `Layer.kind`。
    var tool: AnnotationTool { get }

    /// 工具条上显示哪些样式控件。**只有这里列出的轴才会出现** ——
    /// 马赛克不声明 `.color`，色块就不会占位置。
    var axes: [ToolStyleAxis] { get }

    var defaultStyle: ToolStyle { get }

    /// 落笔方式。默认拖拽。
    var input: ToolInput { get }

    /// 裸键快捷键。nil = 只能从工具条选。
    var shortcut: (keyCode: UInt16, label: String)? { get }

    /// 是否常驻工具条。不常驻的靠快捷键激活，激活后临时露面。
    var isPinnedToBar: Bool { get }

    /// 造一个新层。默认实现给出通用形态，特殊的自己覆盖。
    func makeLayer(_ context: ToolLayerContext) -> Layer

    /// 命中测试（画布空间）。默认按 `handleBounds` 加一圈容差。
    func hitTest(_ layer: Layer, at point: CGPoint, tolerance: Double) -> Bool

    /// 参与缩放的控制点。默认八个全上。
    var resizeHandles: [ResizeHandle] { get }

    /// 控制点画在图层的什么位置（图层自己的坐标空间）。
    /// 默认按外接框取；线段类要按 start/end 取端点 —— 负宽高合法，方向不能丢。
    func handleLocation(_ handle: ResizeHandle, on layer: Layer) -> CGPoint

    /// 控制点画成端点圆点（线段类）还是方块（矩形类）。
    /// 是表现，但属于「这个工具长什么样」，所以归描述符管。
    var usesEndpointHandles: Bool { get }

    /// 按控制点缩放。默认整形 rect。
    func resize(
        _ original: Layer, handle: ResizeHandle, delta: CGPoint, pixelScale: Double
    ) -> Layer

    /// 缩到多小就算「缩没了」（缩没的整层恢复原样、不入撤销栈）。默认宽高都要 ≥ 4。
    func meetsMinimumSize(_ layer: Layer) -> Bool

    // MARK: 移动语义
    //
    // 大多数工具的"移动"就是移动 layer.rect。
    // 特殊工具（放大镜的 display 区域、画笔的路径点）需要额外的同步逻辑。

    /// 拖动起点命中了图层的哪个区域。默认：源区域。
    func moveTarget(_ layer: Layer, at point: CGPoint) -> LayerMoveTarget

    /// 特殊区域拖动：只移动特殊区域（不移动 layer.rect）。返回 nil 表示不消费。
    func moveSpecialRegion(_ layer: Layer, by delta: CGPoint) -> Layer?

    /// layer.rect 被移动后，同步附属数据（display origin / strokePoints）。
    func afterSourceMove(_ layer: Layer, by delta: CGPoint) -> Layer

    // MARK: 滚轮调整

    /// 是否支持滚轮调整特殊参数（如放大镜倍率）。
    var supportsScroll: Bool { get }

    /// 滚轮调整特殊参数。返回 nil 表示不消费（未命中或已在边界）。
    func scrollAdjust(_ layer: Layer, deltaY: CGFloat) -> Layer?

    // MARK: 绘制
    //
    // 坐标系由调用方给定：上下文已经翻成左上原点，图层坐标直接可用。
    // 同一份代码同时服务预览（画布空间）和导出（图像像素空间）——
    // 两者的差异全部体现在 `lineWidth` / `fontSize` 上，由投影换算好。

    /// 在其余矢量层**之下**绘制的部分（如放大镜的放大内容、裁剪的压暗框、
    /// 马赛克的预渲染贴片）。默认不画。
    func drawBelow(_ layer: Layer, preview: CGImage?, baseImage: CGImage?, canvasSize: CGSize, in ctx: CGContext)

    /// 画一层。默认什么都不画 —— 马赛克是图像级滤镜、裁剪改的是画布，
    /// 它们不参与逐层矢量绘制（见 `LayerRenderer.render` 的一、二两步）。
    func draw(_ layer: Layer, in ctx: CGContext)

    /// 这一类图层要在其余矢量层**之下**、且多层合并成一次绘制。
    /// 聚光灯是唯一的用例：所有亮区合成一张遮罩，标注本身不该被压暗。
    var drawsMerged: Bool { get }

    /// `drawsMerged` 为真时的合并绘制。传进来的是本类的全部图层。
    func drawMerged(_ layers: [Layer], in ctx: CGContext)
}

// MARK: - 默认实现
//
// 绝大多数工具是「拖一个矩形、按矩形命中、八个控制点」，那些只需要声明
// tool / axes / defaultStyle 三样。默认实现在这里，特殊语义各自覆盖。

extension AnnotationToolDescriptor {

    var input: ToolInput { .drag }
    var shortcut: (keyCode: UInt16, label: String)? { nil }
    var isPinnedToBar: Bool { false }
    var resizeHandles: [ResizeHandle] { ResizeHandle.resizeHandles }

    var usesEndpointHandles: Bool { false }

    func handleLocation(_ handle: ResizeHandle, on layer: Layer) -> CGPoint {
        handle.point(in: layer.handleBounds)
    }

    func makeLayer(_ context: ToolLayerContext) -> Layer {
        baseLayer(context)
    }

    /// 所有工具共用的那半个造层：颜色、线宽、字号，以及**按声明的轴**烤参数。
    ///
    /// 没声明的轴一律保持 nil —— 渲染器遇到 nil 走旧的硬编码默认，
    /// 旧图层因此行为不变。覆盖 `makeLayer` 的工具应当先调它再改自己那部分。
    func baseLayer(_ context: ToolLayerContext) -> Layer {
        var layer = Layer(
            kind: tool.layerKind,
            rect: LRect(from: context.from, to: context.to),
            color: context.color,
            lineWidth: context.style.value(for: .width) * context.strokeScale,
            text: "",
            fontSize: context.style.value(for: .fontSize) * context.strokeScale
        )
        for axis in axes {
            axis.descriptor.bakeToLayer?(&layer, context.style)
        }
        return layer
    }

    func hitTest(_ layer: Layer, at point: CGPoint, tolerance: Double) -> Bool {
        layer.handleBounds.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
    }

    func resize(
        _ original: Layer, handle: ResizeHandle, delta: CGPoint, pixelScale: Double
    ) -> Layer {
        var layer = original
        layer.rect = LRect(handle.apply(delta: delta, to: original.rect.cg))
        return layer
    }

    func meetsMinimumSize(_ layer: Layer) -> Bool {
        let rect = layer.rect.cg
        return rect.width >= ToolGeometry.minimumSide && rect.height >= ToolGeometry.minimumSide
    }

    // MARK: 移动语义（默认：只动 rect）

    func moveTarget(_ layer: Layer, at point: CGPoint) -> LayerMoveTarget { .source }

    func moveSpecialRegion(_ layer: Layer, by delta: CGPoint) -> Layer? { nil }

    func afterSourceMove(_ layer: Layer, by delta: CGPoint) -> Layer { layer }

    // MARK: 滚轮调整（默认：不支持）

    var supportsScroll: Bool { false }

    func scrollAdjust(_ layer: Layer, deltaY: CGFloat) -> Layer? { nil }

    func drawBelow(_ layer: Layer, preview: CGImage?, baseImage: CGImage?, canvasSize: CGSize, in ctx: CGContext) {}

    func draw(_ layer: Layer, in ctx: CGContext) {}

    var drawsMerged: Bool { false }

    func drawMerged(_ layers: [Layer], in ctx: CGContext) {}
}

/// 工具实现之间共用的几何小工具。放在协议外面 ——
/// 它们是纯函数，没有理由挂在某一个描述符上。
enum ToolGeometry {

    /// 最小边长（画布单位）。
    static let minimumSide = 4.0

    /// 点到线段的距离。线段类工具的命中测试用它。
    static func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> Double {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }
}

// MARK: - 登记处

/// 工具注册表。`BuiltinTools.all` 是唯一的登记处。
enum ToolRegistry {

    /// 声明顺序即工具条顺序，也是设置页里快捷键清单的顺序。
    static var descriptors: [any AnnotationToolDescriptor] { BuiltinTools.all }

    /// 按工具取描述符。
    ///
    /// 忘了登记时返回一份保守的默认而不是崩溃 —— 这条兜底救过一次：
    /// `AnnotationTool` 加了 case 却没在注册表补行，界面照常能用。
    static func descriptor(for tool: AnnotationTool) -> any AnnotationToolDescriptor {
        descriptors.first { $0.tool == tool } ?? FallbackTool(tool: tool)
    }

    /// 从图层反查描述符。效果层不是工具，返回 nil。
    static func descriptor(for kind: Layer.Kind) -> (any AnnotationToolDescriptor)? {
        AnnotationTool(kind: kind).map { descriptor(for: $0) }
    }

    /// 常驻工具条的工具（由各描述符自己声明）。
    static var pinnedTools: [AnnotationTool] {
        descriptors.filter(\.isPinnedToBar).map(\.tool)
    }

    /// 全部裸键快捷键，含开头的「指针」。设置页的按键说明由它生成。
    static var shortcuts: [ToolShortcut] {
        [ToolShortcut(keyCode: KeyCode.v, tool: nil, label: "V")]
            + descriptors.compactMap { descriptor in
                descriptor.shortcut.map {
                    ToolShortcut(keyCode: $0.keyCode, tool: descriptor.tool, label: $0.label)
                }
            }
    }

    /// 未登记工具的兜底：拖矩形、八个控制点、颜色 + 线宽。
    private struct FallbackTool: AnnotationToolDescriptor {
        let tool: AnnotationTool
        var axes: [ToolStyleAxis] { [.color, .width] }
        var defaultStyle: ToolStyle { ToolStyle() }
    }
}

// MARK: - 共享路径工具（画笔/荧光笔）

extension ToolLayerContext {
    /// strokePoints 的包围盒；空数组返回 .zero。
    var strokeBoundingRect: CGRect {
        guard !strokePoints.isEmpty else { return .zero }
        let xs = strokePoints.map(\.x)
        let ys = strokePoints.map(\.y)
        return CGRect(
            x: xs.min() ?? 0, y: ys.min() ?? 0,
            width: (xs.max() ?? 0) - (xs.min() ?? 0),
            height: (ys.max() ?? 0) - (ys.min() ?? 0)
        )
    }
}

extension Layer {
    /// 点到 strokePoints 路径的最近距离是否 ≤ pad。
    func hitTestStroke(at point: CGPoint, pad: CGFloat) -> Bool {
        guard let points = strokePoints, !points.isEmpty else { return false }
        return points.contains { hypot(point.x - $0.x, point.y - $0.y) <= pad }
    }

    /// Catmull-Rom → 贝塞尔平滑（≥4 点）；短路径退化为折线。
    /// 调用者需已设置 strokeColor / lineWidth / lineCap / lineJoin。
    func addStrokePath(to ctx: CGContext) {
        guard let points = strokePoints, points.count >= 2 else { return }
        ctx.move(to: points[0])
        if points.count >= 4 {
            for i in 0..<(points.count - 1) {
                let p0 = points[max(0, i - 1)]
                let p1 = points[i]
                let p2 = points[i + 1]
                let p3 = points[min(points.count - 1, i + 2)]
                let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
                let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
                ctx.addCurve(to: p2, control1: c1, control2: c2)
            }
        } else {
            for i in 1..<points.count {
                ctx.addLine(to: points[i])
            }
        }
    }
}
