import Foundation

enum AnnotationTool: CaseIterable {
    case rect
    case ellipse
    case arrow
    case text
    case highlight
    case pixelate
    /// 直线与裁剪不进覆盖层/钉图的常驻工具条（`ToolbarRegistry.pinnedTools` 不含它们），
    /// 只通过快捷键激活；图库编辑器的工具栏则全量展示。
    case line
    case crop
    /// 序号标记：点击落点，自动递增编号。
    case counter
    /// 聚光灯：矩形亮区，区域外整体压暗。
    case spotlight
    /// 测量：拖出矩形/线段，旁边标注图像像素尺寸。
    case dimension
    /// 自由画笔：跟手画路径，Catmull-Rom 平滑。
    case pencil
    /// 橡皮擦：拖动擦除路径经过的标注层。
    case eraser
    /// 放大镜：框选区域放大显示。
    case magnifier

    var layerKind: Layer.Kind {
        switch self {
        case .rect: return .rect
        case .ellipse: return .ellipse
        case .arrow: return .arrow
        case .text: return .text
        case .highlight: return .highlight
        case .pixelate: return .pixelate
        case .line: return .line
        case .crop: return .crop
        case .counter: return .counter
        case .spotlight: return .spotlight
        case .dimension: return .dimension
        case .pencil: return .pencil
        case .eraser: return .eraser
        case .magnifier: return .magnifier
        }
    }

    var symbolName: String { layerKind.symbolName }
    var title: String { layerKind.displayName }
}


/// 工具的键盘快捷键。
///
/// **唯一真相**。此前覆盖层和钉图窗口各有一份 `toolShortcuts` 字典，
/// 而且已经漂移（钉图那份缺方向键）；设置页里的按键说明是第三份手写文本，
/// 与实际映射没有任何代码关联 —— 改了映射说明不会跟着变。
struct ToolShortcut {
    let keyCode: UInt16
    /// nil 表示指针模式。
    let tool: AnnotationTool?
    /// 展示用的按键名，设置页的帮助文本由它生成。
    let label: String

    var toolName: String { tool?.title ?? "指针" }
}

extension AnnotationTool {

    /// 第二栏平铺 +「标注」菜单列出的常用标注工具。
    /// 非常用工具（椭圆/裁剪/橡皮擦/高亮/直线/序号/聚光灯/测量）通过快捷键激活。
    static let commonTools: [AnnotationTool] = [.rect, .arrow, .pencil, .text, .pixelate]

    /// 全部裸键绑定。**唯一真相**，由各工具的描述符自己声明（见 `BuiltinTools`）——
    /// 此前这里是一张手写的表，加工具要记得回来补一行，忘了就只能从工具条选。
    static var shortcuts: [ToolShortcut] { ToolRegistry.shortcuts }

    /// 返回值是双层可选：外层 nil 表示这个键没绑工具，内层 nil 表示指针模式。
    static func shortcut(forKeyCode keyCode: UInt16) -> AnnotationTool?? {
        shortcuts.first { $0.keyCode == keyCode }.map { $0.tool }
    }
}
