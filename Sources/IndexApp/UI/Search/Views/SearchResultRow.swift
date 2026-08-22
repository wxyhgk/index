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
        .frame(height: 52)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.primary.opacity(0.08))
            } else if isHovering {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.primary.opacity(0.04))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { isHovering = $0 }
        .animation(reduceMotion ? .none : .easeOut(duration: 0.1), value: isHovering)
        .animation(reduceMotion ? .none : .easeOut(duration: 0.1), value: isSelected)
    }

    @ViewBuilder
    private var iconTile: some View {
        if let thumbnail {
            Image(nsImage: thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 36, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(.primary.opacity(0.05))
                .frame(width: 36, height: 36)
                .overlay {
                    Image(systemName: entry.kindIcon)
                        .font(.system(size: 15, weight: .thin))
                        .foregroundStyle(.secondary)
                }
        }
    }

    private var textColumn: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(entry.title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
            if !entry.subtitle.isEmpty {
                HStack(spacing: 3) {
                    Circle()
                        .fill(.quaternary)
                        .frame(width: 2.5, height: 2.5)
                    Text(entry.subtitle)
                        .font(.system(size: 11, weight: .light))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
    }

    private var timeLabel: some View {
        HStack(spacing: 3) {
            Image(systemName: "clock")
                .font(.system(size: 9, weight: .thin))
                .foregroundStyle(.quaternary)
            Text(entry.timestamp, format: .relative(presentation: .named))
                .font(.system(size: 10, weight: .light))
                .foregroundStyle(.quaternary)
                .monospacedDigit()
        }
    }
}
