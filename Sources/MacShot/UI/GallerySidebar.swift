import SwiftUI

// MARK: - 侧边栏（固定的顶层选项列表）
//
// 这里**只画一列选项**，不认识任何一个具体选项装了什么 —— 内容由
// `GalleryDestination` 各自提供（见 GalleryDestination.swift 顶部那张结构图）。
//
// 曾经这个文件是 500 行：四组可折叠的筛选行（资料库 / 分类 / 标签 / 应用）、
// 各自的计数、各自的展开状态、标签的重命名与删除、拖放打标签、App 图标缓存，
// 全部硬编码在一个视图里。加一组要改视图 + 加计数 + 加折叠状态 + 改布局，
// 删一组反过来再做一遍；而且列表长度随库里的数据浮动，从 4 行到 20 行不等。
// 现在长度由我们决定，固定、可预期。
//
// 关于材质：**什么都不加**。面板底是 `DS.panelFill` 纯色 + rim 描边。
// 每窗口只允许一个 behindWindow 材质，而窗底本来就不透明 ——
// 在它上面再叠一层材质只会采样到自家底色，白付一次离屏。

struct GallerySidebar: View {

    /// 当前选中的选项 id。真相在 `GalleryView`，这里只是它的一个入口。
    @Binding var selection: String

    private var destinations: [any GalleryDestination] {
        GalleryDestinationRegistry.shared.ordered()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.s1) {
            ForEach(destinations, id: \.id) { destination in
                row(destination)
            }
            Spacer(minLength: 0)
        }
        .padding(DS.s2)
    }

    private func row(_ destination: any GalleryDestination) -> some View {
        SidebarOptionRow(
            title: destination.title,
            symbol: destination.symbol,
            badge: destination.badge(),
            isSelected: selection == destination.id
        ) {
            selection = destination.id
        }
    }
}

/// 一行选项。样式统一在这里 —— 同一列里出现两种行高或两种选中态，
/// 是「看着杂」最直接的来源。
private struct SidebarOptionRow: View {

    let title: String
    let symbol: String
    let badge: Int?
    let isSelected: Bool
    let action: () -> Void

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: DS.s2) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 18)
                Text(title)
                    .font(.system(size: 13))
                    .lineLimit(1)
                Spacer(minLength: DS.s1)
                if let badge {
                    Text("\(badge)")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
            .padding(.horizontal, DS.s2)
            .frame(height: 32)
            .background(fill, in: RoundedRectangle(cornerRadius: DS.radiusSmall, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: DS.radiusSmall, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(DS.Motion.micro(reduced: reduceMotion), value: hovering)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    /// 选中用 accent 的淡染而不是实心填充 —— 实心会把文字压成白字块，
    /// 而这一列的文字正是要读的内容（同 spatial-ui-spec §7.1：同屏只一处上强调色）。
    private var fill: Color {
        if isSelected { return .accentColor.opacity(hovering ? 0.22 : 0.16) }
        guard hovering else { return .clear }
        return scheme == .dark ? .white.opacity(0.06) : .black.opacity(0.05)
    }
}
