import SwiftUI

// ============================================================
// MARK: - 收藏 tab detail 布局
//
// 返回按钮 + 标题 + 计数，下方按 route 分发：
//   · shot detail：GalleryGrid + GalleryInspectorPanel
//   · clipboard detail：ClipboardFavoritesGrid + ClipboardInspectorPanelHost
// ============================================================

struct CollectionsDetailView: View {
    let store: ShotStore
    let viewModel: GalleryViewModel
    let route: CollectionsNavigationState.Route
    let collections: [ShotCollectionSummary]
    let clipboardFavorites: [ClipboardHistoryItem]
    let clipboardFavoritesThumbnails: [Int64: NSImage]
    let clipboardFavoritesAppIcons: [String: NSImage]
    let onClose: () -> Void

    @AppStorage("galleryInspectorShown") private var showInspector = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .top, spacing: DS.Shell.panelGap) {
            VStack(alignment: .leading, spacing: 0) {
                detailHeader
                content
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .floatingPanel()

            if showInspector {
                inspector
                    .frame(width: DS.Shell.inspectorWidth)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(DS.Motion.standard(reduced: reduceMotion), value: showInspector)
    }

    // MARK: 内容分支

    @ViewBuilder
    private var content: some View {
        switch route {
        case .favorites, .collection:
            GalleryGrid(
                store: store,
                viewModel: viewModel,
                scope: scope,
                chrome: .libraryPanel
            )
        case .clipboardFavorites:
            ClipboardFavoritesGrid(
                items: clipboardFavorites,
                thumbnails: clipboardFavoritesThumbnails,
                appIcons: clipboardFavoritesAppIcons
            )
        }
    }

    @ViewBuilder
    private var inspector: some View {
        switch route {
        case .favorites, .collection:
            GalleryInspectorPanel(isPresented: $showInspector, store: store, viewModel: viewModel)
        case .clipboardFavorites:
            ClipboardInspectorPanelHost()
        }
    }

    // MARK: 页头

    private var detailHeader: some View {
        HStack(spacing: DS.s3) {
            Button(action: onClose) {
                Label("收藏", systemImage: "chevron.left")
                    .font(.system(size: DS.font13, weight: .medium))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])

            Image(systemName: symbol)
                .font(.system(size: DS.font24, weight: .medium))
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: DS.s1 / 2) {
                Text(title)
                    .font(.title2.weight(.bold))
                    .lineLimit(1)
                Text(count)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer()
        }
        .padding(.horizontal, DS.s5)
        .padding(.top, DS.s4)
        .padding(.bottom, DS.s2)
    }

    // MARK: 路由元信息

    private var symbol: String {
        switch route {
        case .favorites: return "star.fill"
        case .collection: return "rectangle.stack.fill"
        case .clipboardFavorites: return "doc.on.clipboard"
        }
    }

    private var color: Color {
        switch route {
        case .favorites: return .yellow
        case .collection: return .accentColor
        case .clipboardFavorites: return DS.clipboardImageBar
        }
    }

    private var title: String {
        switch route {
        case .favorites: return "快速收藏"
        case .collection(let id): return collections.first { $0.id == id }?.name ?? "收藏集"
        case .clipboardFavorites: return "剪贴板收藏"
        }
    }

    private var count: String {
        switch route {
        case .favorites, .collection:
            return "\(viewModel.displayShots.count) 张图片"
        case .clipboardFavorites:
            return "\(clipboardFavorites.count) 个项目"
        }
    }

    private var scope: GalleryContentScope {
        switch route {
        case .favorites: return .favorites
        case .collection(let id): return .collection(id: id, title: title)
        case .clipboardFavorites: return .favorites
        }
    }
}
