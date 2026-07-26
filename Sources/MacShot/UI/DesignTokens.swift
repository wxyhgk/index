import SwiftUI

/// 全局设计 token。图库改版期间由并行分支共同遵守的约定，
/// 间距、圆角、分类色都收敛到这里 —— 视图代码里不再出现魔法数。
///
/// 字阶约定（不需要常量，直接用系统字体）只有 4 档：
///   `.title3.weight(.semibold)`  分组标题
///   `.body`                      正文
///   `.caption.weight(.medium)`   卡片主行 / 强调小字
///   `.caption2`                  次级小字（时间戳 / 胶囊）
enum DS {

    // MARK: - 间距（4px 基数）

    static let s1: CGFloat = 4
    static let s2: CGFloat = 8
    static let s3: CGFloat = 12
    static let s4: CGFloat = 16
    static let s5: CGFloat = 24

    // MARK: - 圆角（只有两档）

    /// 按钮 / 胶囊等小件。
    static let radiusSmall: CGFloat = 6
    /// 卡片 / 分组块。
    static let radiusCard: CGFloat = 10

    // MARK: - 分类色

    /// 分类名 → 颜色。侧边栏色点用；其它要按分类着色的地方也走这张表，
    /// 保证同一分类处处同色。未知分类（包括「其它」）兜底灰色。
    static func categoryColor(_ name: String) -> Color {
        switch name {
        case "代码": return .blue
        case "浏览器": return .teal
        case "聊天": return .green
        case "设计": return .pink
        case "终端": return .indigo
        case "文档": return .orange
        case "笔记": return .yellow
        case "影音": return .purple
        case "效率": return .mint
        default: return .gray
        }
    }
}
