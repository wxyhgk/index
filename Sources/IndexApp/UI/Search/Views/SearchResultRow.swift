import SwiftUI

// MARK: - 搜索结果单行（苹果黑白风）
//
// 52pt 行高。左侧 36pt 图标（图片缩略图 / SF Symbol thin）。
// 中间标题 + 来源（小圆点分隔）。右侧时间（clock 图标）。

struct SearchResultRow: View {
    let entry: SearchEntry
    let thumbnail: NSImage?
    let isSelected: Bool
    let onSelect: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
                RoundedRectangle(cornerRadius: DS.radiusMedium, style: .continuous)
                    .fill(SearchPanelMetrics.selectedRowFill)
            } else if isHovering {
                RoundedRectangle(cornerRadius: DS.radiusMedium, style: .continuous)
                    .fill(SearchPanelMetrics.hoveredRowFill)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { isHovering = $0 }
        .animation(
            reduceMotion ? .none : .easeOut(duration: SearchPanelMetrics.hoverDuration),
            value: isHovering
        )
        .animation(
            reduceMotion ? .none : .easeOut(duration: SearchPanelMetrics.hoverDuration),
            value: isSelected
        )
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
                .fill(SearchPanelMetrics.thumbnailPlaceholderFill)
                .frame(
                    width: SearchPanelMetrics.thumbnailSide,
                    height: SearchPanelMetrics.thumbnailSide
                )
                .overlay {
                    Image(systemName: entry.kindIcon)
                        .font(.system(size: DS.font15, weight: .thin))
                        .foregroundStyle(.secondary)
                }
        }
    }

    private var textColumn: some View {
        VStack(alignment: .leading, spacing: SearchPanelMetrics.textColumnSpacing) {
            Text(entry.title)
                .font(.system(size: DS.font13, weight: .medium))
                .foregroundStyle(.primary)
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
                        .font(.system(size: DS.font11, weight: .light))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
    }

    private var timeLabel: some View {
        HStack(spacing: SearchPanelMetrics.metadataSpacing) {
            Image(systemName: "clock")
                .font(.system(size: DS.font9, weight: .thin))
                .foregroundStyle(.quaternary)
            Text(entry.timestamp, format: .relative(presentation: .named))
                .font(.system(size: DS.font10, weight: .light))
                .foregroundStyle(.quaternary)
                .monospacedDigit()
        }
    }
}
