import SwiftUI
import AppKit

// ============================================================
// MARK: - 剪贴板卡片公共组件
//
// 浮动面板（ClipboardHistoryCard）和主窗口 tab（ClipboardGridCard）
// 共享的视觉部分只保留内容预览与必要状态。类型、时间、来源 App、尺寸等
// 元数据已经存在于筛选器和详情面板，不在每张卡片上重复布局。
// ============================================================

// MARK: 卡片内容

/// 剪贴板卡片只有两种固定规格。尺寸集中在这里，主窗口和快捷弹窗
/// 不再各自维护一份字面量，避免布局尺寸与 SwiftUI 内容帧悄悄漂移。
enum ClipboardCardMetrics {
    static let gridWidth: CGFloat = 180
    static let gridHeight: CGFloat = 160
    static let popupSide: CGFloat = 190
}

struct ClipboardCardBody: View, Equatable {
    let item: ClipboardHistoryItem
    var textLineLimit: Int = 6
    var store: ClipboardHistoryStore = .shared

    @Environment(\.colorScheme) private var scheme

    static func == (lhs: ClipboardCardBody, rhs: ClipboardCardBody) -> Bool {
        lhs.item == rhs.item
            && lhs.textLineLimit == rhs.textLineLimit
            && lhs.store === rhs.store
    }

    var body: some View {
        contentArea
            .overlay(alignment: .topTrailing) { pinnedBadge }
            .overlay(alignment: .bottomLeading) { customTitle }
    }

    @ViewBuilder
    private var contentArea: some View {
        ZStack {
            RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous)
                .fill(DS.thumbnailBacking(scheme))

            switch item.kind {
            case .text:
                Text(item.text ?? item.summary ?? "")
                    .font(.system(size: DS.font13))
                    .lineSpacing(2)
                    .lineLimit(textLineLimit)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(DS.s3)
            case .image:
                if let url = store.content(of: item).assetURL {
                    CachedImage(
                        url: url,
                        key: item.thumbnailCacheKey,
                        contentMode: .fill
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                } else {
                    placeholderIcon("photo")
                }
            case .file:
                VStack(spacing: DS.s2) {
                    Image(systemName: "doc")
                        .font(.system(size: DS.font20))
                        .foregroundStyle(.tertiary)
                    Text(item.displayName)
                        .font(.system(size: DS.font12, weight: .medium))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }
                .padding(DS.s2)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous))
        .overlay {
            let rim = DS.rim(.content, scheme, hovering: false)
            RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous)
                .strokeBorder(rim.solidColor, lineWidth: rim.lineWidth)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var pinnedBadge: some View {
        if item.pinned {
            Image(systemName: "pin.fill")
                .font(.system(size: DS.font11, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(DS.panelFill(.overlay).opacity(0.88), in: Circle())
                .padding(DS.s1)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var customTitle: some View {
        if let title = item.title, !title.isEmpty, item.kind == .image {
            Text(title)
                .font(.system(size: DS.font11, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, DS.s2)
                .padding(.vertical, DS.s1)
                .background(DS.panelFill(.overlay).opacity(0.82), in: Capsule())
                .padding(DS.s1)
                .allowsHitTesting(false)
        }
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

extension ClipboardHistoryItem {
    var thumbnailCacheKey: String { "clipboard:\(contentHash)" }
    var viewportIdentity: String {
        id.map { "clipboard-item:\($0)" } ?? "clipboard-hash:\(contentHash)"
    }
}
