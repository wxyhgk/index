import SwiftUI

// MARK: - 搜索结果单行
//
// 56pt 行高。左侧 40pt 图标（图片缩略图 / SF Symbol medium）。
// 选中态用 accent 淡染（与主 App 卡片选中同语言），hover 用中性提亮。

struct SearchResultRow: View {
    let entry: SearchEntry
    let thumbnail: NSImage?
    let isSelected: Bool
    let onSelect: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: DS.s3) {
            iconTile
            textColumn
            Spacer(minLength: DS.s2)
            timeLabel
        }
        .padding(.horizontal, DS.s3)
        .frame(height: SearchPanelMetrics.resultRowHeight)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous)
                    .fill(DS.accentFillSelected)
            } else if isHovering {
                RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous)
                    .fill(DS.hoverFill)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { isHovering = $0 }
        .animation(DS.Motion.micro(reduced: reduceMotion), value: isHovering)
        .animation(DS.Motion.micro(reduced: reduceMotion), value: isSelected)
    }

    @ViewBuilder
    private var iconTile: some View {
        if let thumbnail {
            Image(nsImage: thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(
                    width: SearchPanelMetrics.thumbnailSide,
                    height: SearchPanelMetrics.thumbnailSide
                )
                .clipShape(RoundedRectangle(cornerRadius: DS.radiusSmall, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: DS.radiusSmall, style: .continuous)
                .fill(DS.iconPlaceholderFill)
                .frame(
                    width: SearchPanelMetrics.thumbnailSide,
                    height: SearchPanelMetrics.thumbnailSide
                )
                .overlay {
                    Image(systemName: entry.kindIcon)
                        .font(.system(size: DS.font15, weight: .medium))
                        .foregroundStyle(isSelected ? DS.accent : .secondary)
                }
        }
    }

    private var textColumn: some View {
        VStack(alignment: .leading, spacing: SearchPanelMetrics.textColumnSpacing) {
            Text(entry.title)
                .font(.system(size: DS.font13, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? .primary : .primary)
                .lineLimit(1)
            if !entry.subtitle.isEmpty {
                HStack(spacing: SearchPanelMetrics.metadataSpacing) {
                    Circle()
                        .fill(.quaternary)
                        .frame(
                            width: SearchPanelMetrics.subtitleBulletSide,
                            height: SearchPanelMetrics.subtitleBulletSide
                        )
                    Text(entry.subtitle)
                        .font(.system(size: DS.font11, weight: .regular))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
    }

    private var timeLabel: some View {
        HStack(spacing: SearchPanelMetrics.metadataSpacing) {
            Image(systemName: "clock")
                .font(.system(size: DS.font9, weight: .medium))
                .foregroundStyle(.quaternary)
            Text(entry.timestamp, format: .relative(presentation: .named))
                .font(.system(size: DS.font10, weight: .regular))
                .foregroundStyle(.quaternary)
                .monospacedDigit()
        }
    }
}
