import SwiftUI
import AppKit

// ============================================================
// MARK: - 剪贴板卡片公共组件
//
// 浮动面板（ClipboardHistoryCard）和主窗口 tab（ClipboardGridCard）
// 共享的视觉部分：内容区 + 装饰层。
// 两个卡片只保留尺寸差异和各自的 overlay（如收藏星）。
// ============================================================

// MARK: 卡片内容（header + content + footer）

struct ClipboardCardBody: View {
    let item: ClipboardHistoryItem
    let thumbnail: NSImage?
    let appIcon: NSImage?
    var textLineLimit: Int = 6

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        VStack(spacing: 0) {
            CardHeaderBar(
                label: item.kind.displayLabel,
                time: item.capturedAt,
                appIcon: appIcon,
                barColor: item.kind.barColor,
                pinned: item.pinned
            )
            contentArea
            footer
        }
    }

    @ViewBuilder
    private var contentArea: some View {
        ZStack {
            RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous)
                .fill(DS.thumbnailBacking(scheme))

            switch item.kind {
            case .text:
                Text(item.text ?? item.summary ?? "")
                    .font(.system(size: DS.font12))
                    .lineLimit(textLineLimit)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(DS.s2)
            case .image:
                if let thumbnail {
                    Color.clear
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .overlay(
                            Image(nsImage: thumbnail)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        )
                        .clipped()
                } else {
                    placeholderIcon("photo")
                }
            case .file:
                placeholderIcon("doc")
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous))
        .overlay {
            let rim = DS.rim(.content, scheme, hovering: false)
            RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous)
                .strokeBorder(rim.gradient, lineWidth: rim.lineWidth)
                .blendMode(reduceTransparency ? .normal : rim.blend)
                .allowsHitTesting(false)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(item.displayName)
                .font(.system(size: DS.font12, weight: .medium))
                .lineLimit(1)
            Text(item.kind.footerText(for: item))
                .font(.system(size: DS.font11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, DS.s2)
        .padding(.vertical, DS.s1)
    }

    private func placeholderIcon(_ name: String) -> some View {
        VStack {
            Image(systemName: name)
                .font(.system(size: DS.font20))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: 卡片装饰（rim + shadow + hover + selection）

struct ClipboardCardChrome: ViewModifier {
    let isSelected: Bool
    let isHovering: Bool
    var showsSelection: Bool = true

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        content
            .background(DS.panelFill(.resting))
            .clipShape(RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous))
            .overlay { cardRim }
            .compositingGroup()
            .overlay { if showsSelection { selectionRing } }
            .overlay(alignment: .topTrailing) { if showsSelection { selectionBadge } }
            .scaleEffect(isHovering ? DS.Lift.hoverScale : 1)
            .offset(y: isHovering && !reduceMotion ? DS.Lift.hoverY : 0)
            .animation(DS.Motion.micro(reduced: reduceMotion), value: isHovering)
            .animation(showsSelection ? DS.Motion.standard(reduced: reduceMotion) : .none, value: isSelected)
            .shadow(
                color: hoverShadow.color,
                radius: hoverShadow.radius,
                y: hoverShadow.y
            )
            .contentShape(Rectangle())
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
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }

    @ViewBuilder
    private var selectionBadge: some View {
        if isSelected {
            Image(systemName: "checkmark")
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
            .strokeBorder(rim.gradient, lineWidth: rim.lineWidth)
            .blendMode(reduceTransparency ? .normal : rim.blend)
            .allowsHitTesting(false)
    }

    private var hoverShadow: DS.Shadow {
        guard scheme != .dark, isHovering else { return .none }
        return DS.shadow(.raised, scheme)
    }
}

// MARK: 类型过滤 + 搜索栏（浮动面板和主窗口 tab 共用）

struct ClipboardFilterBar: View {
    @ObservedObject var viewModel: ClipboardHistoryViewModel
    var searchWidth: CGFloat = 140

    var body: some View {
        HStack(spacing: DS.s1) {
            filterTab("全部", kind: nil)
            filterTab("文本", kind: .text)
            filterTab("图片", kind: .image)
            filterTab("文件", kind: .file)
        }
        HStack(spacing: DS.s1) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: DS.font12))
                .foregroundStyle(.tertiary)
            TextField("搜索", text: $viewModel.query)
                .textFieldStyle(.plain)
                .font(.system(size: DS.font13))
                .frame(width: searchWidth)
                .onChange(of: viewModel.query) { _ in
                    viewModel.searchChanged()
                }
        }
        .padding(.horizontal, DS.s2)
        .padding(.vertical, DS.s1)
        .background(DS.iconPlaceholderFill, in: RoundedRectangle(cornerRadius: DS.radiusSmall))
    }

    private func filterTab(_ title: String, kind: ClipboardHistoryKind?) -> some View {
        Button {
            viewModel.setTypeFilter(kind)
        } label: {
            Text(title)
                .font(.system(size: DS.font12, weight: viewModel.typeFilter == kind ? .semibold : .regular))
                .padding(.horizontal, DS.s2)
                .padding(.vertical, DS.s1)
                .background(
                    viewModel.typeFilter == kind
                        ? DS.accent.opacity(0.15)
                        : Color.clear,
                    in: RoundedRectangle(cornerRadius: DS.radiusSmall)
                )
                .foregroundStyle(viewModel.typeFilter == kind ? DS.accent : .secondary)
        }
        .buttonStyle(.plain)
    }
}

// MARK: 类型元数据（消灭三份 switch）

extension ClipboardHistoryKind {
    var displayLabel: String {
        switch self {
        case .text: return "文本"
        case .image: return "图片"
        case .file: return "文件"
        }
    }

    var barColor: Color {
        switch self {
        case .text: return DS.clipboardTextBar
        case .image: return DS.clipboardImageBar
        case .file: return DS.clipboardFileBar
        }
    }

    func footerText(for item: ClipboardHistoryItem) -> String {
        switch self {
        case .text:
            let count = (item.text ?? "").count
            return "\(count) 个字符"
        case .image:
            return item.summary ?? "图片"
        case .file:
            return item.summary ?? "文件"
        }
    }
}
