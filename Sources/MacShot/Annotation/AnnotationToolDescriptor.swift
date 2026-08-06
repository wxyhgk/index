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

/// 工具落笔的方式。
enum ToolInput {
    /// 拖出形体：矩形、椭圆、箭头、线、马赛克…
    case drag
    /// 点一下就落一层：文字、序号。
    case click
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

    /// 按控制点缩放。默认整形 rect。
    func resize(
        _ original: Layer, handle: ResizeHandle, delta: CGPoint, pixelScale: Double
    ) -> Layer

    /// 缩到多小就算「缩没了」（缩没的整层恢复原样、不入撤销栈）。默认宽高都要 ≥ 4。
    func meetsMinimumSize(_ layer: Layer) -> Bool
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

    func makeLayer(_ context: ToolLayerContext) -> Layer {
        baseLayer(context)
    }

    /// 所有工具共用的那半个造层：颜色、线宽、字号，以及**按声明的轴**烤参数。
    ///
    /// 没声明的轴一律保持 nil —— 渲染器遇到 nil 走旧的硬编码默认，
    /// 旧图层因此行为不变。覆盖 `makeLayer` 的工具应当先调它再改自己那部分。
    func baseLayer(_ context: ToolLayerContext) -> Layer {
        var color = context.color
        if axes.contains(.opacity) {
            color.a = context.style.value(for: .opacity)
        }
        var layer = Layer(
            kind: tool.layerKind,
            rect: LRect(from: context.from, to: context.to),
            color: color,
            lineWidth: context.style.value(for: .width) * context.strokeScale,
            text: "",
            fontSize: context.style.value(for: .fontSize) * context.strokeScale
        )
        if axes.contains(.blockSize) { layer.blockScale = context.style.value(for: .blockSize) }
        if axes.contains(.dim) { layer.dim = context.style.value(for: .dim) }
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
