import AppKit

/// 内置标注工具。
///
/// 这个文件是「新增标注工具」的唯一登记处 —— 加一个工具就是在下面写一个 struct，
/// 再往 `all` 里加一行。状态机、控制点、工具条、快捷键表都不需要改。
///
/// 声明顺序 = 工具条顺序 = 设置页快捷键清单的顺序。

// MARK: - 拖矩形的那一类（默认实现就够）

struct RectTool: AnnotationToolDescriptor {
    let tool = AnnotationTool.rect
    let axes: [ToolStyleAxis] = [.color, .width]
    let defaultStyle = ToolStyle()
    let shortcut: (keyCode: UInt16, label: String)? = (KeyCode.r, "R")
    let isPinnedToBar = true
}

struct EllipseTool: AnnotationToolDescriptor {
    let tool = AnnotationTool.ellipse
    let axes: [ToolStyleAxis] = [.color, .width]
    let defaultStyle = ToolStyle()
    let shortcut: (keyCode: UInt16, label: String)? = (KeyCode.o, "O")
}

/// 高亮默认橙色：荧光笔的直觉色。透明度是它自己那根轴，不再是写死的 0.4。
struct HighlightTool: AnnotationToolDescriptor {
    let tool = AnnotationTool.highlight
    let axes: [ToolStyleAxis] = [.color, .opacity]
    let defaultStyle = ToolStyle(colorIndex: 1)
    let shortcut: (keyCode: UInt16, label: String)? = (KeyCode.h, "H")
}

/// 不吃颜色 —— 渲染器根本不读 `layer.color`。
struct PixelateTool: AnnotationToolDescriptor {
    let tool = AnnotationTool.pixelate
    let axes: [ToolStyleAxis] = [.blockSize]
    let defaultStyle = ToolStyle()
    let shortcut: (keyCode: UInt16, label: String)? = (KeyCode.p, "P")
    let isPinnedToBar = true
}

/// 同样不吃颜色，只有一根压暗轴。
struct SpotlightTool: AnnotationToolDescriptor {
    let tool = AnnotationTool.spotlight
    let axes: [ToolStyleAxis] = [.dim]
    let defaultStyle = ToolStyle()
    // 裸 S 选聚光灯；⌘S 在两处键盘路由里都先判修饰键，保存不受影响。
    let shortcut: (keyCode: UInt16, label: String)? = (KeyCode.s, "S")
}

/// 裁剪没有任何可调样式。
struct CropTool: AnnotationToolDescriptor {
    let tool = AnnotationTool.crop
    let axes: [ToolStyleAxis] = []
    let defaultStyle = ToolStyle()
    // C 被取色器占用，裁剪用 X。
    let shortcut: (keyCode: UInt16, label: String)? = (KeyCode.x, "X")
}

// MARK: - 线段类：两端控制点、按距离命中、长度决定死活

/// 直线与箭头的共同语义。两者只差绘制，行为完全一致。
protocol SegmentTool: AnnotationToolDescriptor {}

extension SegmentTool {

    /// 只有两端（`topLeft` ↔ `rect.start`、`bottomRight` ↔ `rect.end`）。
    var resizeHandles: [ResizeHandle] { [.topLeft, .bottomRight] }

    /// 按点到线段的距离判定，带一圈容差方便点中细线。
    func hitTest(_ layer: Layer, at point: CGPoint, tolerance: Double) -> Bool {
        ToolGeometry.distance(from: point, toSegment: layer.rect.start, layer.rect.end)
            <= tolerance + layer.lineWidth / 2
    }

    /// 拖端点，不是整形矩形 —— 负宽高合法，方向不能丢。
    func resize(
        _ original: Layer, handle: ResizeHandle, delta: CGPoint, pixelScale: Double
    ) -> Layer {
        var layer = original
        if handle == .topLeft {
            layer.rect.x = original.rect.x + delta.x
            layer.rect.y = original.rect.y + delta.y
            layer.rect.w = original.rect.w - delta.x
            layer.rect.h = original.rect.h - delta.y
        } else {
            layer.rect.w = original.rect.w + delta.x
            layer.rect.h = original.rect.h + delta.y
        }
        return layer
    }

    /// 只要长度别缩没。
    func meetsMinimumSize(_ layer: Layer) -> Bool {
        max(abs(layer.rect.w), abs(layer.rect.h)) >= ToolGeometry.minimumSide
    }
}

struct ArrowTool: SegmentTool {
    let tool = AnnotationTool.arrow
    let axes: [ToolStyleAxis] = [.color, .width]
    let defaultStyle = ToolStyle()
    let shortcut: (keyCode: UInt16, label: String)? = (KeyCode.a, "A")
    let isPinnedToBar = true
}

struct LineTool: SegmentTool {
    let tool = AnnotationTool.line
    let axes: [ToolStyleAxis] = [.color, .width]
    let defaultStyle = ToolStyle()
    let shortcut: (keyCode: UInt16, label: String)? = (KeyCode.l, "L")
}

// MARK: - 文字：点击落点、按量出的文字范围命中、缩放改字号

struct TextTool: AnnotationToolDescriptor {
    let tool = AnnotationTool.text
    // 吃字号，不吃线宽 —— 旧版本这两者共用一个下标，
    // 调矩形边框粗细会顺手改掉文字大小。
    let axes: [ToolStyleAxis] = [.color, .fontSize]
    let defaultStyle = ToolStyle()
    let input = ToolInput.click
    let shortcut: (keyCode: UInt16, label: String)? = (KeyCode.t, "T")
    let isPinnedToBar = true

    /// `rect` 只存锚点（w/h 恒为 0），实际范围由 `handleBounds` 按当前字号量出来。
    func makeLayer(_ context: ToolLayerContext) -> Layer {
        var layer = baseLayer(context)
        layer.text = ""
        return layer
    }

    /// 拖控制点改的是**字号**，不是矩形。
    func resize(
        _ original: Layer, handle: ResizeHandle, delta: CGPoint, pixelScale: Double
    ) -> Layer {
        var layer = original
        let bounds = original.handleBounds
        let resized = handle.apply(delta: delta, to: bounds)
        layer.rect.x = resized.minX
        layer.rect.y = resized.minY
        if bounds.height > 0 {
            layer.fontSize = max(4, original.fontSize * resized.height / bounds.height)
        }
        return layer
    }

    func meetsMinimumSize(_ layer: Layer) -> Bool {
        layer.fontSize >= 4
    }
}

// MARK: - 序号：点击落点、圆形命中、缩放保持正圆

struct CounterTool: AnnotationToolDescriptor {
    let tool = AnnotationTool.counter
    let axes: [ToolStyleAxis] = [.color, .fontSize]
    let defaultStyle = ToolStyle()
    let input = ToolInput.click
    let shortcut: (keyCode: UInt16, label: String)? = (KeyCode.n, "N")

    /// 点击处是圆心，`rect` 存外接正方形；编号扫现有序号层取最大值 +1。
    /// 刻意不在删除时重排 —— 删掉中间某个序号后，后续编号保持不变。
    func makeLayer(_ context: ToolLayerContext) -> Layer {
        var layer = baseLayer(context)
        let diameter = max(28 * context.strokeScale, layer.fontSize * 1.4)
        layer.rect = LRect(CGRect(
            x: context.from.x - diameter / 2,
            y: context.from.y - diameter / 2,
            width: diameter,
            height: diameter
        ))
        let next = (context.existing
            .filter { $0.kind == .counter }
            .compactMap { Int($0.text) }
            .max() ?? 0) + 1
        layer.text = String(next)
        return layer
    }

    /// 徽章是圆的，按圆形区域命中，别让四个角白占位置。
    func hitTest(_ layer: Layer, at point: CGPoint, tolerance: Double) -> Bool {
        let rect = layer.rect.cg
        return hypot(point.x - rect.midX, point.y - rect.midY) <= rect.width / 2 + tolerance
    }

    func resize(
        _ original: Layer, handle: ResizeHandle, delta: CGPoint, pixelScale: Double
    ) -> Layer {
        var layer = original
        layer.rect = LRect(Self.square(handle: handle, delta: delta, original: original.rect.cg))
        return layer
    }

    /// 保持圆形：直径 d 拖角取 max(w, h)、拖边取被拖的那一维；
    /// 被拖控制点的对侧保持不动（拖边时另一轴居中锚定）。
    static func square(handle: ResizeHandle, delta: CGPoint, original: CGRect) -> CGRect {
        let applied = handle.apply(delta: delta, to: original)
        let d: CGFloat
        switch handle {
        case .top, .bottom: d = applied.height
        case .left, .right: d = applied.width
        default:            d = max(applied.width, applied.height)
        }

        let minX: CGFloat
        switch handle {
        case .topLeft, .left, .bottomLeft:       minX = original.maxX - d
        case .topRight, .right, .bottomRight:    minX = original.minX
        default:                                 minX = original.midX - d / 2
        }
        let minY: CGFloat
        switch handle {
        case .topLeft, .top, .topRight:          minY = original.minY
        case .bottomLeft, .bottom, .bottomRight: minY = original.maxY - d
        default:                                 minY = original.midY - d / 2
        }
        return CGRect(x: minX, y: minY, width: d, height: d)
    }
}

// MARK: - 测量：生成时就把数值烤进 text

struct DimensionTool: AnnotationToolDescriptor {
    let tool = AnnotationTool.dimension
    let axes: [ToolStyleAxis] = [.color, .width]
    let defaultStyle = ToolStyle()
    let shortcut: (keyCode: UInt16, label: String)? = (KeyCode.m, "M")

    func makeLayer(_ context: ToolLayerContext) -> Layer {
        var layer = baseLayer(context)
        Self.prepare(&layer, pixelScale: context.pixelScale)
        return layer
    }

    func resize(
        _ original: Layer, handle: ResizeHandle, delta: CGPoint, pixelScale: Double
    ) -> Layer {
        var layer = original
        layer.rect = LRect(handle.apply(delta: delta, to: original.rect.cg))
        Self.prepare(&layer, pixelScale: pixelScale)
        return layer
    }

    /// 允许单维为 0（吸附形态），所以只看长边。
    func meetsMinimumSize(_ layer: Layer) -> Bool {
        max(abs(layer.rect.w), abs(layer.rect.h)) >= ToolGeometry.minimumSide
    }

    /// 整形。拖拽过程中每帧都会经过这里（`pendingLayer` 每帧重建图层）。
    ///   · 近似横/竖的拖拽（薄轴不足 8 像素）吸附成单维 —— 薄轴收拢为 0，
    ///     渲染层据此退化为双箭头线段，只标长度
    ///   · 标签数值按 `pixelScale` 换算成图像像素后烤进 `text`：
    ///     覆盖层画布是点、导出是像素，只有生成时算好才能保证预览和成品显示同一个数
    static func prepare(_ layer: inout Layer, pixelScale: Double) {
        var rect = layer.rect.cg.standardized
        if min(rect.width, rect.height) * pixelScale < 8 {
            rect = rect.width >= rect.height
                ? CGRect(x: rect.minX, y: rect.midY, width: rect.width, height: 0)
                : CGRect(x: rect.midX, y: rect.minY, width: 0, height: rect.height)
        }
        layer.rect = LRect(rect)

        let w = Int((rect.width * pixelScale).rounded())
        let h = Int((rect.height * pixelScale).rounded())
        if rect.height == 0 {
            layer.text = "\(w) px"
        } else if rect.width == 0 {
            layer.text = "\(h) px"
        } else {
            layer.text = "\(w) × \(h) px"
        }
    }
}

// MARK: - 登记

enum BuiltinTools {

    /// 在这里登记。顺序即工具条上的显示顺序。
    static let all: [any AnnotationToolDescriptor] = [
        RectTool(),
        EllipseTool(),
        ArrowTool(),
        LineTool(),
        TextTool(),
        HighlightTool(),
        PixelateTool(),
        CropTool(),
        CounterTool(),
        SpotlightTool(),
        DimensionTool()
    ]
}
