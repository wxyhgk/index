import Foundation

/// 工具条右侧动作组。截图和钉图共用同一个枚举，只是各自展示的子集不同 ——
/// 「钉图」在已经钉住的窗口上没有意义，换成「关闭」。
enum ToolbarAction: Equatable {
    case pin
    case copy
    case save
    case close
    /// 只完成，不做别的。没有对应按钮 —— 只由回车触发，见 Settings.EnterBehavior。
    case done

    var symbolName: String {
        switch self {
        case .pin: return "pin.fill"
        case .copy: return "doc.on.doc"
        case .save: return "square.and.arrow.down"
        case .close: return "xmark"
        case .done: return "checkmark"
        }
    }

    var title: String {
        switch self {
        case .pin: return "钉图"
        case .copy: return "复制"
        case .save: return "保存"
        case .close: return "关闭"
        case .done: return "完成"
        }
    }

    /// 截图选区确认后。
    static let capture: [ToolbarAction] = [.pin, .copy, .save]
    /// 钉图窗口上。
    static let pinned: [ToolbarAction] = [.copy, .save, .close]
}
