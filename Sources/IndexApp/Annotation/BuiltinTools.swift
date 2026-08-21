import Foundation

/// 内置标注工具的登记处。
///
/// 加一个工具 = 在 `Tools/` 下新建一个文件写实现，再往下面的数组加一行。
/// 实现分散在各自的文件里，正是为了让两个人同时加工具时**只在这一行相遇** ——
/// 从前「一个工具」这个概念散在十个文件里，每处都是一个 switch。
///
/// 声明顺序 = 工具条顺序 = 设置页快捷键清单的顺序。
enum BuiltinTools {

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
