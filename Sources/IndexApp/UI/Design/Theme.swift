import SwiftUI

// ============================================================
// MARK: - Theme（兼容转发层，已收敛到 DS）
//
// 职责：
//   DS  = 唯一事实来源（间距 / 圆角 / 颜色 / 表面 / 阴影 / 动效 / 外壳）
//   Theme = 已废弃的跨端抽象，仅为历史调用点兼容而保留，全部转发到 DS。
//
// 约定：
//   - 新代码一律 `DS.xxx`，不再 `Theme.shared.spacing.s4`。
//   - `Theme` / `MacTheme` / `Spacing` / `Radius` 均已标记 deprecated，
//     仅作兼容转发，下一个大版本可直接删除本文件。
//   - 数值不再在 Theme 侧硬编码，一律读 DS，避免双轨漂移。
// ============================================================

@available(*, deprecated, message: "Theme 已收敛到 DS，请直接使用 DS（见 DesignTokens.swift）。本协议仅为兼容转发。")
protocol Theme {
    var spacing: Spacing { get }
    var radius: Radius { get }
    func categoryColor(_ category: ShotClassifier.Category) -> Color
    func categoryColor(_ name: String) -> Color
}

extension Theme {
    func categoryColor(_ name: String) -> Color {
        guard let category = ShotClassifier.Category(rawValue: name) else {
            return categoryColor(.other)
        }
        return categoryColor(category)
    }
}

@available(*, deprecated, message: "Spacing 已收敛到 DS.s1…s5，请直接使用 DS。")
struct Spacing {
    let s1: CGFloat = DS.s1
    let s2: CGFloat = DS.s2
    let s3: CGFloat = DS.s3
    let s4: CGFloat = DS.s4
    let s5: CGFloat = DS.s5
}

@available(*, deprecated, message: "Radius 已收敛到 DS.radius*，请直接使用 DS。")
struct Radius {
    let small: CGFloat = DS.radiusSmall
    let card: CGFloat = DS.radiusCard
    let chip: CGFloat = DS.radiusChip
    let panel: CGFloat = DS.radiusPanel
    let modal: CGFloat = DS.radiusModal
}

/// macOS 主题：全部转发到 DS。
@available(*, deprecated, message: "MacTheme 已收敛到 DS，请直接使用 DS。")
struct MacTheme: Theme {
    let spacing = Spacing()
    let radius = Radius()
    func categoryColor(_ category: ShotClassifier.Category) -> Color { DS.categoryColor(category) }
    func categoryColor(_ name: String) -> Color { DS.categoryColor(name) }
    @available(*, deprecated, message: "Use DS directly")
    static let shared: Theme = MacTheme()
}
