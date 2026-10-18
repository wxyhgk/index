import SwiftUI

// ============================================================
// MARK: - 卡片装饰 ViewModifier（rim + shadow + hover + selection）
// ============================================================

struct ClipboardCardChrome: ViewModifier {
    let isSelected: Bool
    let isHovering: Bool
    var showsSelection: Bool = true
    var selectionOrdinal: Int? = nil

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .clipShape(RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous))
            .overlay { cardRim }
            .overlay { if showsSelection { selectionRing } }
            .overlay(alignment: .topTrailing) { if showsSelection { selectionBadge } }
            .contentShape(Rectangle())
            .scaleEffect(isHovering ? DS.Lift.hoverScale : 1.0)
            .offset(y: isHovering ? DS.Lift.hoverY : 0)
            .animation(DS.Motion.micro(reduced: reduceMotion), value: isHovering)
            .animation(DS.Motion.standard(reduced: reduceMotion), value: isSelected)
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
            Group {
                if let selectionOrdinal {
                    Text("\(selectionOrdinal)")
                } else {
                    Image(systemName: "checkmark")
                }
            }
                .font(.system(size: DS.font11, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(DS.accent, in: Circle())
                .overlay {
                    Circle().strokeBorder(DS.badgeStroke, lineWidth: 1)
                }
                .padding(DS.s2)
                .transition(.scale(scale: 0.6).combined(with: .opacity))
                .allowsHitTesting(false)
        }
    }

    private var cardRim: some View {
        let rim = DS.rim(isHovering ? .raised : .content, scheme, hovering: isHovering)
        return RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous)
            .strokeBorder(rim.solidColor, lineWidth: rim.lineWidth)
            .allowsHitTesting(false)
    }
}
