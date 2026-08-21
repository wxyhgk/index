import SwiftUI

// ============================================================
// MARK: - 剪贴板收藏（收藏 tab 里的入口卡片 + 详情网格）
//
// ClipboardFavoritesCard 是 overview 网格里的入口卡片，
// ClipboardFavoritesGrid 是点击后展示的收藏条目网格。
// 数据源是 ClipboardHistoryStore.shared.favorites()，
// 和剪贴板 tab 共享 ClipboardGridCard 卡片组件。
// ============================================================

struct ClipboardFavoritesCard: View {
    let items: [ClipboardHistoryItem]
    let thumbnails: [Int64: NSImage]
    let appIcons: [String: NSImage]
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: DS.s3) {
                HStack(spacing: DS.s2) {
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: DS.font18, weight: .semibold))
                        .foregroundStyle(DS.clipboardImageBar)
                        .frame(width: 30, height: 30)
                        .background(DS.clipboardImageBar.opacity(0.12), in: RoundedRectangle(cornerRadius: DS.radiusChip))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("剪贴板收藏").font(.headline).lineLimit(1)
                        Text("\(items.count) 项 · 收藏的剪贴板内容")
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
                        if items.indices.contains(index) {
                            let item = items[index]
                            clipboardPreview(item)
                        } else {
                            RoundedRectangle(cornerRadius: DS.radiusChip, style: .continuous)
                                .fill(DS.insetSurface)
                                .frame(maxWidth: .infinity)
                                .frame(height: 82)
                                .overlay {
                                    Image(systemName: "doc.on.clipboard")
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
        .accessibilityLabel("剪贴板收藏，\(items.count) 个项目")
    }

    private var hoverShadow: DS.Shadow {
        guard scheme != .dark, hovering else { return .none }
        return DS.shadow(.raised, scheme)
    }

    @ViewBuilder
    private func clipboardPreview(_ item: ClipboardHistoryItem) -> some View {
        Group {
            if item.kind == .image, let id = item.id, let thumb = thumbnails[id] {
                Image(nsImage: thumb)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                VStack {
                    Image(systemName: item.kind == .text ? "textformat" : "doc")
                        .font(.system(size: DS.font20))
                        .foregroundStyle(.quaternary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 82)
        .background(DS.insetSurface)
        .clipShape(RoundedRectangle(cornerRadius: DS.radiusChip, style: .continuous))
    }

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous)
    }
}

struct ClipboardFavoritesGrid: View {
    let items: [ClipboardHistoryItem]
    let thumbnails: [Int64: NSImage]
    let appIcons: [String: NSImage]

    var body: some View {
        if items.isEmpty {
            ContentUnavailableView(
                "暂无剪贴板收藏",
                systemImage: "doc.on.clipboard",
                description: Text("在剪贴板 tab 右键条目选择「收藏」即可加入")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 180), spacing: DS.s3)],
                    spacing: DS.s3
                ) {
                    ForEach(items) { item in
                        ClipboardGridCard(
                            item: item,
                            thumbnail: item.id.flatMap { thumbnails[$0] },
                            appIcon: item.sourceApp.flatMap { appIcons[$0] }
                        )
                        .contextMenu {
                            Button("复制") {
                                ClipboardHistoryViewModel.shared.copyBack(item)
                            }
                            Button(item.isFavorite ? "取消收藏" : "收藏") {
                                ClipboardHistoryViewModel.shared.toggleFavorite(item)
                            }
                            Divider()
                            Button("删除", role: .destructive) {
                                ClipboardHistoryViewModel.shared.delete(item)
                            }
                        }
                    }
                }
                .padding(.horizontal, DS.s4)
                .padding(.vertical, DS.s3)
            }
        }
    }
}
