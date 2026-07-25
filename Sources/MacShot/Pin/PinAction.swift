import AppKit

/// 钉图窗口上可执行的操作。
///
/// 悬停工具条只放 `primary` 那几个 —— 钉图窗口通常很小，堆满按钮会盖住内容本身。
/// 完整列表留在右键菜单里，两处共用这一个枚举，不会出现两份各自维护的清单。
enum PinAction: CaseIterable {
    case edit
    case copy
    case save
    case gallery
    case close

    var symbolName: String {
        switch self {
        case .edit: return "pencil.tip.crop.circle"
        case .copy: return "doc.on.doc"
        case .save: return "square.and.arrow.down"
        case .gallery: return "photo.on.rectangle"
        case .close: return "xmark"
        }
    }

    var title: String {
        switch self {
        case .edit: return "编辑标注…"
        case .copy: return "复制图片"
        case .save: return "保存…"
        case .gallery: return "在图库中打开"
        case .close: return "关闭"
        }
    }

    /// 悬停工具条上直接给出的操作。
    static let primary: [PinAction] = [.edit, .copy, .close]

    /// 窗口太窄时按这个顺序丢弃；`close` 永远保留。
    static let droppingOrder: [PinAction] = [.copy, .edit]
}
