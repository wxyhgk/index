import SwiftUI

// ============================================================
// MARK: - 收藏 tab 的卡片组件
//
// QuickFavoritesCard / CollectionCard / CollectionCardShell
// 是 overview 网格里的入口卡片，点击后进入对应 detail。
// ============================================================

struct QuickFavoritesCard: View {
    let store: ShotStore
    let previews: [Shot]
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false

    var body: some View {
        CollectionCardShell(
            title: "快速收藏",
            subtitle: "点亮星标即可收进这里",
            count: store.favoriteCount(),
            previews: previews,
            icon: "star.fill",
            iconColor: .yellow,
            store: store,
            hovering: hovering,
            action: action
        )
        .onHover { hovering = $0 }
    }
}

struct CollectionCard: View {
    let collection: ShotCollectionSummary
    let store: ShotStore
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        CollectionCardShell(
            title: collection.name,
            subtitle: collection.note.isEmpty ? "自定义专题集" : collection.note,
            count: collection.itemCount,
            previews: collection.previews,
            icon: "rectangle.stack.fill",
            iconColor: .accentColor,
            store: store,
            hovering: hovering,
            action: action
        )
        .onHover { hovering = $0 }
    }
}

struct CollectionCardShell: View {
    let title: String
    let subtitle: String
    let count: Int
    let previews: [Shot]
    let icon: String
    let iconColor: Color
    let store: ShotStore
    let hovering: Bool
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: DS.s3) {
                HStack(spacing: DS.s2) {
                    Image(systemName: icon)
                        .font(.system(size: DS.font18, weight: .semibold))
                        .foregroundStyle(iconColor)
                        .frame(width: 30, height: 30)
                        .background(iconColor.opacity(0.12), in: RoundedRectangle(cornerRadius: DS.radiusChip))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.headline).lineLimit(1)
                        Text("\(count) 张 · \(subtitle)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }

                HStack(spacing: DS.s2) {
                    ForEach(0..<3, id: \.self) { index in
                        if previews.indices.contains(index) {
                            let shot = previews[index]
                            CachedImage(url: store.thumbnailURL(for: shot), key: shot.sha256)
                                .frame(maxWidth: .infinity)
                                .frame(height: 82)
                                .background(DS.insetSurface)
                                .clipShape(previewShape)
                        } else {
                            previewShape.fill(DS.insetSurface)
                                .frame(maxWidth: .infinity)
                                .frame(height: 82)
                                .overlay {
                                    Image(systemName: "photo")
                                        .foregroundStyle(.quaternary)
                                }
                        }
                    }
                }
            }
            .padding(DS.s3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DS.panelFill(.resting), in: cardShape)
            .overlay {
                let rim = DS.rim(hovering ? .raised : .content, scheme, hovering: hovering)
                cardShape.strokeBorder(rim.gradient, lineWidth: rim.lineWidth)
                    .blendMode(reduceTransparency ? .normal : rim.blend)
                    .allowsHitTesting(false)
            }
            .compositingGroup()
            .contentShape(cardShape)
        }
        .buttonStyle(.plain)
        .scaleEffect(hovering ? DS.Lift.hoverScale : 1)
        .offset(y: hovering && !reduceMotion ? DS.Lift.hoverY : 0)
        .shadow(
            color: hoverShadow.color,
            radius: hoverShadow.radius,
            y: hoverShadow.y
        )
        .animation(DS.Motion.micro(reduced: reduceMotion), value: hovering)
        .accessibilityLabel("\(title)，\(count) 张图片")
    }

    private var hoverShadow: DS.Shadow {
        guard scheme != .dark, hovering else { return .none }
        return DS.shadow(.raised, scheme)
    }

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous)
    }
    private var previewShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: DS.radiusChip, style: .continuous)
    }
}
