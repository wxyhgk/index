import Foundation

// MARK: - 工具样式契约
//
// 在此之前，所有工具共用**一份**全局的 colorIndex / widthIndex：拿箭头选了红色粗线，
// 切到文字就是红色粗体；字号还被线宽绑架（fontSize = 线宽 × 4 + 8），改矩形的线宽
// 会连带改变文字的大小。而高亮透明度、马赛克块大小、聚光灯压暗程度则是彻底硬编码，
// 连全局设置都没有。
//
// 这里把「一个工具有哪些可调参数、默认值是多少」收敛成描述符 + 注册表，
// 与效果层的 `EffectDescriptor` 是同一个思路：
//   · 每个工具各记各的样式，切回来还是上次那套；
//   · 工具条按描述符声明的**样式轴**决定显示哪些控件 ——
//     马赛克不再摆一排点了没反应的色块；
//   · 硬编码的参数变成可调项。

/// 工具可调的样式轴。工具条据此决定显示哪些控件。
enum ToolStyleAxis: String, Codable, CaseIterable {
    case color
    /// 线宽。
    case width
    /// 字号。与线宽解耦 —— 它们本来就是两件不相干的事。
    case fontSize
    /// 高亮的透明度。
    case opacity
    /// 马赛克的块大小（相对默认值的倍率）。
    case blockSize
    /// 聚光灯区域外的压暗程度。
    case dim

    /// 每根轴的档位值。一律三档，工具条上就是三个点。
    var steps: [Double] {
        switch self {
        case .color:     return []                  // 颜色走调色板，不是数值轴
        case .width:     return [2, 4, 8]
        case .fontSize:  return [16, 24, 40]        // 旧公式 线宽×4+8 的等价三档
        case .opacity:   return [0.25, 0.40, 0.60]  // 中档 = 旧硬编码值
        case .blockSize: return [0.6, 1.0, 1.8]     // 中档 = 旧硬编码公式
        case .dim:       return [0.40, 0.55, 0.75]  // 中档 = 旧硬编码值
        }
    }

    /// 工具条上的排序（颜色最前，其余按声明顺序）。
    var order: Int {
        switch self {
        case .color:     return 0
        case .width:     return 100
        case .fontSize:  return 200
        case .opacity:   return 300
        case .blockSize: return 400
        case .dim:       return 500
        }
    }

    var title: String {
        switch self {
        case .color:     return "颜色"
        case .width:     return "粗细"
        case .fontSize:  return "字号"
        case .opacity:   return "透明度"
        case .blockSize: return "颗粒"
        case .dim:       return "压暗"
        }
    }
}

/// 一个工具记住的样式。每根轴存**档位下标**而不是数值 ——
/// 这样将来调整档位值，用户已保存的偏好仍然落在「中档」而不是某个失效的数字上。
struct ToolStyle: Codable, Equatable {
    var colorIndex: Int = 0
    var widthIndex: Int = 1
    var fontSizeIndex: Int = 1
    var opacityIndex: Int = 1
    var blockSizeIndex: Int = 1
    var dimIndex: Int = 1

    init(colorIndex: Int = 0, widthIndex: Int = 1, fontSizeIndex: Int = 1) {
        self.colorIndex = colorIndex
        self.widthIndex = widthIndex
        self.fontSizeIndex = fontSizeIndex
    }

    /// 手写解码：合成的 Codable **不会**使用默认值，缺键就整条失败。
    /// 用户的旧偏好里没有新加的轴，必须逐项 `decodeIfPresent` 兜底。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        colorIndex = try c.decodeIfPresent(Int.self, forKey: .colorIndex) ?? 0
        widthIndex = try c.decodeIfPresent(Int.self, forKey: .widthIndex) ?? 1
        fontSizeIndex = try c.decodeIfPresent(Int.self, forKey: .fontSizeIndex) ?? 1
        opacityIndex = try c.decodeIfPresent(Int.self, forKey: .opacityIndex) ?? 1
        blockSizeIndex = try c.decodeIfPresent(Int.self, forKey: .blockSizeIndex) ?? 1
        dimIndex = try c.decodeIfPresent(Int.self, forKey: .dimIndex) ?? 1
    }

    func index(for axis: ToolStyleAxis) -> Int {
        switch axis {
        case .color:     return colorIndex
        case .width:     return widthIndex
        case .fontSize:  return fontSizeIndex
        case .opacity:   return opacityIndex
        case .blockSize: return blockSizeIndex
        case .dim:       return dimIndex
        }
    }

    mutating func setIndex(_ value: Int, for axis: ToolStyleAxis) {
        switch axis {
        case .color:     colorIndex = value
        case .width:     widthIndex = value
        case .fontSize:  fontSizeIndex = value
        case .opacity:   opacityIndex = value
        case .blockSize: blockSizeIndex = value
        case .dim:       dimIndex = value
        }
    }

    /// 取某根轴的**数值**（颜色轴无数值，返回 0）。越界一律回中档，
    /// 不信任持久化下来的下标。
    func value(for axis: ToolStyleAxis) -> Double {
        let steps = axis.steps
        guard !steps.isEmpty else { return 0 }
        let i = index(for: axis)
        return steps.indices.contains(i) ? steps[i] : steps[steps.count / 2]
    }
}

/// 一个工具的描述符：它用得上哪些样式轴、默认样式是什么。
struct ToolDescriptor {
    let tool: AnnotationTool
    /// 声明顺序即工具条上的顺序。**只有这里列出的轴才会出现在工具条上** ——
    /// 马赛克不声明 `.color`，色块就不会占位置。
    let axes: [ToolStyleAxis]
    let defaultStyle: ToolStyle
}

/// 工具描述符注册表。加一种工具 = 在这里补一条。
@MainActor
enum ToolRegistry {

    static let descriptors: [ToolDescriptor] = [
        .init(tool: .rect,      axes: [.color, .width],    defaultStyle: ToolStyle()),
        .init(tool: .ellipse,   axes: [.color, .width],    defaultStyle: ToolStyle()),
        .init(tool: .arrow,     axes: [.color, .width],    defaultStyle: ToolStyle()),
        .init(tool: .line,      axes: [.color, .width],    defaultStyle: ToolStyle()),
        // 文字与序号吃字号，不吃线宽 —— 旧版本这两者共用一个下标，
        // 调矩形边框粗细会顺手改掉文字大小。
        .init(tool: .text,      axes: [.color, .fontSize], defaultStyle: ToolStyle()),
        .init(tool: .counter,   axes: [.color, .fontSize], defaultStyle: ToolStyle()),
        // 高亮默认橙色：荧光笔的直觉色，且它的透明度独立于其它工具。
        .init(tool: .highlight, axes: [.color, .opacity],  defaultStyle: ToolStyle(colorIndex: 1)),
        .init(tool: .dimension, axes: [.color, .width],    defaultStyle: ToolStyle()),
        // 以下三个不吃颜色：渲染器根本不读 layer.color。
        .init(tool: .pixelate,  axes: [.blockSize],        defaultStyle: ToolStyle()),
        .init(tool: .spotlight, axes: [.dim],              defaultStyle: ToolStyle()),
        .init(tool: .crop,      axes: [],                  defaultStyle: ToolStyle())
    ]

    static func descriptor(for tool: AnnotationTool) -> ToolDescriptor {
        descriptors.first { $0.tool == tool }
            // 新工具忘了登记时给一份保守的默认，而不是崩溃。
            ?? ToolDescriptor(tool: tool, axes: [.color, .width], defaultStyle: ToolStyle())
    }
}

extension AnnotationTool {
    /// 持久化与字典键用的稳定标识（复用图层种类的 rawValue，不另造一套）。
    var id: String { layerKind.rawValue }

    /// 从图层种类反查工具 —— 指针模式下选中一个图层时，
    /// 工具条要按**那一层**的工具显示样式轴。
    init?(kind: Layer.Kind) {
        guard let match = AnnotationTool.allCases.first(where: { $0.layerKind == kind }) else {
            return nil
        }
        self = match
    }
}
