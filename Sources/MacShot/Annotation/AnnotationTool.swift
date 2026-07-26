import Foundation

enum AnnotationTool: CaseIterable {
    case rect
    case ellipse
    case arrow
    case text
    case highlight
    case pixelate

    var layerKind: Layer.Kind {
        switch self {
        case .rect: return .rect
        case .ellipse: return .ellipse
        case .arrow: return .arrow
        case .text: return .text
        case .highlight: return .highlight
        case .pixelate: return .pixelate
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

    static let shortcuts: [ToolShortcut] = [
        ToolShortcut(keyCode: KeyCode.v, tool: nil,        label: "V"),
        ToolShortcut(keyCode: KeyCode.r, tool: .rect,      label: "R"),
        ToolShortcut(keyCode: KeyCode.a, tool: .arrow,     label: "A"),
        ToolShortcut(keyCode: KeyCode.t, tool: .text,      label: "T"),
        ToolShortcut(keyCode: KeyCode.p, tool: .pixelate,  label: "P"),
        ToolShortcut(keyCode: KeyCode.o, tool: .ellipse,   label: "O"),
        ToolShortcut(keyCode: KeyCode.h, tool: .highlight, label: "H")
    ]

    /// 返回值是双层可选：外层 nil 表示这个键没绑工具，内层 nil 表示指针模式。
    static func shortcut(forKeyCode keyCode: UInt16) -> AnnotationTool?? {
        shortcuts.first { $0.keyCode == keyCode }.map { $0.tool }
    }
}
