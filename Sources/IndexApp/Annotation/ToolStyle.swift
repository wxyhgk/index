import Foundation
import AppKit

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

    /// 轴的元数据由 `ToolStyleAxisDescriptor` 统一声明。
    var descriptor: ToolStyleAxisDescriptor {
        ToolStyleAxisDescriptor.descriptor(for: self)
    }

    /// 每根轴的档位值。一律三档，工具条上就是三个点。
    var steps: [Double] { descriptor.steps }

    /// 工具条上的排序（颜色最前，其余按声明顺序）。
    var order: Int { descriptor.order }

    var title: String { descriptor.title }
}

/// 单根样式轴的完整声明 —— **唯一改动点**。
///
/// 新增一根轴只需在这里加一项：steps / order / title / 默认档位 / 存储位置
/// / 绘制 / 落盘键 / 应用与烤制逻辑全部同处，ToolStyle／AnnotationState／
/// BuiltinControls／EditorToolbar 不再各自 switch。
struct ToolStyleAxisDescriptor {
    let axis: ToolStyleAxis
    let order: Int
    let title: String
    let steps: [Double]
    let defaultIndex: Int
    let codingKey: String
    let keyPath: WritableKeyPath<ToolStyle, Int>

    /// AppKit 工具条上的图标绘制（BuiltinControls.ToolParamControl）。
    /// nil 表示不走数值图标（如颜色走 ColorControl）。
    let toolbarDraw: ((CGRect, Int) -> Void)?

    /// 把当前样式应用到已选图层。返回是否生效（blockSize 固定 false）。
    /// strokeScale 仅 width / fontSize 需要。
    let applyToLayer: ((inout Layer, ToolStyle, Double) -> Bool)?

    /// 新建图层时把样式烤进图层（blockScale / dim / opacity 等可选字段）。
    let bakeToLayer: ((inout Layer, ToolStyle) -> Void)?

    // MARK: - 注册表（唯一真相）

    static let all: [ToolStyleAxisDescriptor] = [
        ToolStyleAxisDescriptor(
            axis: .color,
            order: 0,
            title: "颜色",
            steps: [],
            defaultIndex: 0,
            codingKey: "colorIndex",
            keyPath: \ToolStyle.colorIndex,
            toolbarDraw: nil,
            applyToLayer: { layer, style, _ in
                let idx = style.colorIndex
                let palette = AnnotationState.palette
                let base = palette.indices.contains(idx) ? palette[idx] : palette[0]
                var c = base
                if layer.kind == .highlight {
                    c.a = style.value(for: .opacity)
                }
                layer.color = c
                return true
            },
            bakeToLayer: nil
        ),
        ToolStyleAxisDescriptor(
            axis: .width,
            order: 100,
            title: "粗细",
            steps: [2, 4, 8],
            defaultIndex: 1,
            codingKey: "widthIndex",
            keyPath: \ToolStyle.widthIndex,
            toolbarDraw: { frame, index in
                let steps: [Double] = [2, 4, 8]
                guard steps.indices.contains(index) else { return }
                let radius = CGFloat(steps[index]) / 2 + 1.5
                NSColor.white.setFill()
                NSBezierPath(ovalIn: NSRect(
                    x: frame.midX - radius, y: frame.midY - radius,
                    width: radius * 2, height: radius * 2
                )).fill()
            },
            applyToLayer: { layer, style, strokeScale in
                layer.lineWidth = style.value(for: .width) * strokeScale
                return true
            },
            bakeToLayer: nil
        ),
        ToolStyleAxisDescriptor(
            axis: .fontSize,
            order: 200,
            title: "字号",
            steps: [16, 24, 40],
            defaultIndex: 1,
            codingKey: "fontSizeIndex",
            keyPath: \ToolStyle.fontSizeIndex,
            toolbarDraw: { frame, index in
                let size = 9 + CGFloat(index) * 3
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: size, weight: .semibold),
                    .foregroundColor: NSColor.white
                ]
                let text = "A" as NSString
                let bounds = text.size(withAttributes: attrs)
                text.draw(
                    at: NSPoint(x: frame.midX - bounds.width / 2, y: frame.midY - bounds.height / 2),
                    withAttributes: attrs
                )
            },
            applyToLayer: { layer, style, strokeScale in
                layer.fontSize = style.value(for: .fontSize) * strokeScale
                return true
            },
            bakeToLayer: nil
        ),
        ToolStyleAxisDescriptor(
            axis: .opacity,
            order: 300,
            title: "透明度",
            steps: [0.25, 0.40, 0.60],
            defaultIndex: 1,
            codingKey: "opacityIndex",
            keyPath: \ToolStyle.opacityIndex,
            toolbarDraw: { frame, index in
                let steps: [Double] = [0.25, 0.40, 0.60]
                guard steps.indices.contains(index) else { return }
                NSColor.white.withAlphaComponent(steps[index]).setFill()
                NSBezierPath(ovalIn: NSRect(
                    x: frame.midX - 6, y: frame.midY - 6, width: 12, height: 12
                )).fill()
            },
            applyToLayer: { layer, style, _ in
                layer.color.a = style.value(for: .opacity)
                return true
            },
            bakeToLayer: { layer, style in
                layer.color.a = style.value(for: .opacity)
            }
        ),
        ToolStyleAxisDescriptor(
            axis: .blockSize,
            order: 400,
            title: "颗粒",
            steps: [0.6, 1.0, 1.8],
            defaultIndex: 1,
            codingKey: "blockSizeIndex",
            keyPath: \ToolStyle.blockSizeIndex,
            toolbarDraw: { frame, index in
                let counts = [4, 3, 2]
                let n = counts[min(index, counts.count - 1)]
                let side: CGFloat = 12
                let cell = side / CGFloat(n)
                NSColor.white.setFill()
                for row in 0..<n {
                    for col in 0..<n where (row + col) % 2 == 0 {
                        NSBezierPath(rect: NSRect(
                            x: frame.midX - side / 2 + CGFloat(col) * cell,
                            y: frame.midY - side / 2 + CGFloat(row) * cell,
                            width: cell, height: cell
                        )).fill()
                    }
                }
            },
            applyToLayer: { _, _, _ in false },
            bakeToLayer: { layer, style in
                layer.blockScale = style.value(for: .blockSize)
            }
        ),
        ToolStyleAxisDescriptor(
            axis: .dim,
            order: 500,
            title: "压暗",
            steps: [0.40, 0.55, 0.75],
            defaultIndex: 1,
            codingKey: "dimIndex",
            keyPath: \ToolStyle.dimIndex,
            toolbarDraw: { frame, index in
                let steps: [Double] = [0.40, 0.55, 0.75]
                guard steps.indices.contains(index) else { return }
                NSColor.black.withAlphaComponent(steps[index]).setFill()
                let dot = NSRect(x: frame.midX - DS.toolDotSize / 2, y: frame.midY - DS.toolDotSize / 2, width: DS.toolDotSize, height: DS.toolDotSize)
                NSBezierPath(ovalIn: dot).fill()
                NSColor.white.withAlphaComponent(0.5).setStroke()
                let ring = NSBezierPath(ovalIn: dot)
                ring.lineWidth = DS.hairline
                ring.stroke()
            },
            applyToLayer: { layer, style, _ in
                layer.dim = style.value(for: .dim)
                return true
            },
            bakeToLayer: { layer, style in
                layer.dim = style.value(for: .dim)
            }
        ),
    ]

    static func descriptor(for axis: ToolStyleAxis) -> ToolStyleAxisDescriptor {
        guard let found = all.first(where: { $0.axis == axis }) else {
            fatalError("Missing descriptor for axis \(axis)")
        }
        return found
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
    /// 现由描述符注册表驱动，新增轴无需再改这里。
    init(from decoder: Decoder) throws {
        // 先填默认值，再按描述符逐项覆盖
        self.init()
        struct DynamicKey: CodingKey {
            var stringValue: String
            init(stringValue: String) { self.stringValue = stringValue }
            var intValue: Int? { nil }
            init?(intValue: Int) { nil }
        }
        let c = try decoder.container(keyedBy: DynamicKey.self)
        for desc in ToolStyleAxisDescriptor.all {
            let key = DynamicKey(stringValue: desc.codingKey)
            if let value = try c.decodeIfPresent(Int.self, forKey: key) {
                self[keyPath: desc.keyPath] = value
            } else {
                self[keyPath: desc.keyPath] = desc.defaultIndex
            }
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: DynamicCodingKey.self)
        for desc in ToolStyleAxisDescriptor.all {
            let key = DynamicCodingKey(stringValue: desc.codingKey)
            try c.encode(self[keyPath: desc.keyPath], forKey: key)
        }
    }

    private struct DynamicCodingKey: CodingKey {
        var stringValue: String
        init(stringValue: String) { self.stringValue = stringValue }
        var intValue: Int? { nil }
        init?(intValue: Int) { nil }
    }

    func index(for axis: ToolStyleAxis) -> Int {
        self[keyPath: axis.descriptor.keyPath]
    }

    mutating func setIndex(_ value: Int, for axis: ToolStyleAxis) {
        self[keyPath: axis.descriptor.keyPath] = value
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

// 工具描述符（样式轴 + 行为）已经搬进 `AnnotationToolDescriptor` 契约，
// 登记处是 `BuiltinTools.all`。这个文件只留「样式」本身：轴的定义与档位值。

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
