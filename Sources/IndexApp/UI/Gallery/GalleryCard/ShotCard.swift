import SwiftUI

// MARK: - Gallery card
//
// A grid cell is deliberately only the content preview. Time is already encoded
// by section headers, kind by the active library tab, and metadata by the inspector.
// Repeating those on every card made the grid noisy and multiplied layout work.

struct ShotCard: View, Equatable {
    let shot: Shot
    let height: CGFloat
    let isSelected: Bool
    let isFavorite: Bool
    let isRecording: Bool
    let isHovering: Bool
    let onToggleFavorite: () -> Void
    var store: ShotStore

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var thumbnailURL: URL { store.thumbnailURL(for: shot) }

    private var contentKind: ContentKind {
        ContentKind(rawValue: shot.contentKind) ?? .image
    }

    /// The grid recreates the action closure, but for the same shot/store it has
    /// identical semantics. Ignoring it lets EquatableView keep this subtree stable
    /// while the hosting view receives a new size proposal on every resize frame.
    static func == (lhs: ShotCard, rhs: ShotCard) -> Bool {
        lhs.shot == rhs.shot
            && lhs.height == rhs.height
            && lhs.isSelected == rhs.isSelected
            && lhs.isFavorite == rhs.isFavorite
            && lhs.isRecording == rhs.isRecording
            && lhs.isHovering == rhs.isHovering
            && lhs.store === rhs.store
    }

    var body: some View {
        thumbnail
            .contentShape(Rectangle())
            .overlay { selectionRing }
            // 只做合成阶段的缩放，不改变网格测量尺寸；复用池无需重新
            // layout，CachedImage 也不会因为悬停重新解码。2% 足够让卡片
            // 有抬起感，又不会明显侵占相邻卡片。
            .scaleEffect(isHovering ? DS.Lift.hoverScale : 1)
            // 只恢复选中反馈：蓝框淡入、勾选徽章弹出。它们不参与布局，
            // 也不需要阴影 / blur / drawingGroup，复用网格里仍是廉价动效。
            .animation(DS.Motion.micro(reduced: reduceMotion), value: isHovering)
            .animation(DS.Motion.standard(reduced: reduceMotion), value: isSelected)
            .accessibilityLabel(shot.primaryDisplayName)
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous)
    }

    private var thumbnail: some View {
        ZStack {
            shape.fill(DS.thumbnailBacking(scheme))
            contentPreview
        }
        .frame(height: height)
        .clipShape(shape)
        .overlay { thumbnailRim }
        .overlay(alignment: .topLeading) { favoriteButton }
        .overlay(alignment: .topTrailing) { selectionBadge }
        .overlay { recordingBadge }
    }

    @ViewBuilder
    private var contentPreview: some View {
        if contentKind == .image {
            // Keep the overwhelmingly common image path free of type erasure and
            // plug-in lookup. This is the hot path while scrolling and resizing.
            CachedImage(url: thumbnailURL, key: shot.sha256)
        } else {
            // Structured cards (currently Markdown) still need their registered
            // renderer. The card simplification previously hard-coded CachedImage
            // here, which made Markdown notes appear blank or as stale thumbnails.
            PluginRegistry.shared.mode(for: contentKind).renderer.render(
                shot: shot,
                height: height,
                store: store,
                isHovering: isHovering
            )
        }
    }

    private var thumbnailRim: some View {
        let rim = DS.rim(isHovering ? .raised : .content, scheme, hovering: isHovering)
        return shape
            .strokeBorder(rim.solidColor, lineWidth: rim.lineWidth)
            .allowsHitTesting(false)
    }

    @ViewBuilder
    private var selectionRing: some View {
        if isSelected {
            RoundedRectangle(
                cornerRadius: DS.radiusOuter(inner: DS.radiusCard, offset: DS.Glow.ringOffset),
                style: .continuous
            )
            .strokeBorder(
                DS.accent.opacity(DS.Glow.ringOpacity(scheme)),
                lineWidth: DS.Glow.ringWidth
            )
            .padding(-DS.Glow.ringOffset)
            .transition(.opacity)
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var selectionBadge: some View {
        if isSelected {
            Image(systemName: "checkmark")
                .font(.system(size: DS.font11, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: DS.badgeSelection, height: DS.badgeSelection)
                .background(DS.accent, in: Circle())
                .overlay { Circle().strokeBorder(DS.badgeStroke, lineWidth: DS.hairline) }
                .padding(DS.s2)
                .transition(.scale(scale: DS.badgePopScale).combined(with: .opacity))
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var recordingBadge: some View {
        if isRecording {
            Image(systemName: "play.fill")
                .font(.system(size: DS.font20, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: DS.badgeRecording, height: DS.badgeRecording)
                .background(DS.panelFill(.overlay).opacity(DS.badgeBackingOpacity), in: Circle())
                .allowsHitTesting(false)
                .accessibilityLabel("录屏")
        }
    }

    @ViewBuilder
    private var favoriteButton: some View {
        if isHovering || isFavorite {
            Button(action: onToggleFavorite) {
                Image(systemName: isFavorite ? "star.fill" : "star")
                    .font(.system(size: DS.font12, weight: .semibold))
                    .foregroundStyle(isFavorite ? DS.favoriteFill : .primary)
                    .frame(width: DS.badgeFavorite, height: DS.badgeFavorite)
                    .background(DS.panelFill(.overlay).opacity(DS.badgeBackingOpacity), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .padding(DS.s1)
            .help(isFavorite ? "取消收藏" : "收藏")
        }
    }
}
