import SwiftUI
import UniformTypeIdentifiers

// MARK: - 卡片
//
// 网格里的一张缩略图卡片（悬停、选中描边、收藏星、分类胶囊、标注角标），
// 以及它拖出去时用的 Transferable 载荷。

/// 拖出卡片的载荷。构造只是拷一个 Shot 值 —— 渲染含标注的成品 PNG
/// 发生在**接收方真正收文件时**（FileRepresentation 的导出闭包），
/// 目录复用暂存栏的拖拽临时目录，下次启动统一清理；渲染失败退回原图路径。
struct ShotDragFile: Transferable {
    let shot: Shot

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .png) { file in
            let url = await MainActor.run { file.writeRenderedPNG() }
            return SentTransferredFile(url, allowAccessingOriginalFile: true)
        }
    }

    /// 重活集中在这：读原图 → 合成最新修订 → 编码 → 写临时文件。
    /// 只在一次真实的拖放里执行一次。
    @MainActor
    fileprivate func writeRenderedPNG() -> URL {
        let store = ShotStore.shared
        let fallback = store.originalURL(for: shot)

        guard let base = store.originalImage(for: shot) else { return fallback }
        let rendered = LayerRenderer.render(
            base: base,
            layers: store.latestRevision(for: shot)?.imageLayers ?? Layers()
        )
        guard let png = ImageCodec.pngData(from: rendered) else { return fallback }

        let dir = ShelfController.dragFileDirectory
            .appendingPathComponent(shot.sha256, isDirectory: true)
        let url = dir.appendingPathComponent(ImageExporter.suggestedName(for: shot))
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try png.write(to: url, options: .atomic)
            return url
        } catch {
            return fallback
        }
    }
}

struct ShotCard: View {
    let shot: Shot
    let height: CGFloat
    let isSelected: Bool
    /// 收藏态由父级（已订阅 store 的 GalleryGrid）传入，卡片本身保持不订阅。
    let isFavorite: Bool
    /// 分类 / 标注角标同样由父级批量查好传入。
    let category: String?
    let isAnnotated: Bool
    let onToggleFavorite: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovering = false
    /// 悬停 0.3s 后才浮出尺寸条 —— 快速扫过不打扰。
    @State private var showsDimensions = false

    // 刻意不用 @ObservedObject 订阅 store —— 只需要一个文件路径，
    // 订阅了会导致任何 store 变化都重建全部缩略图。
    private var thumbnailURL: URL { ShotStore.shared.thumbnailURL(for: shot) }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.s2) {
            thumbnail
            caption
        }
        .onHover { isHovering = $0 }
        .task(id: isHovering) {
            guard isHovering else {
                showsDimensions = false
                return
            }
            try? await Task.sleep(for: .seconds(0.3))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.15)) { showsDimensions = true }
        }
    }

    private var thumbnail: some View {
        ZStack {
            RoundedRectangle(cornerRadius: DS.radiusCard)
                .fill(.quaternary.opacity(0.5))
            CachedImage(url: thumbnailURL, key: shot.sha256)
                .clipShape(RoundedRectangle(cornerRadius: DS.radiusCard))
        }
        .frame(height: height)
        // 尺寸浮条盖在底边，先叠再裁 —— 让浮条跟着卡片圆角走。
        .overlay(alignment: .bottom) { dimensionBar }
        .clipShape(RoundedRectangle(cornerRadius: DS.radiusCard))
        .overlay {
            // 深色模式悬停不加阴影（黑底上看不见），改为整体提亮一档。
            if colorScheme == .dark && isHovering {
                RoundedRectangle(cornerRadius: DS.radiusCard)
                    .fill(Color.white.opacity(0.05))
                    .allowsHitTesting(false)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: DS.radiusCard)
                .strokeBorder(Color.primary.opacity(strokeOpacity), lineWidth: 1)
        }
        .overlay(alignment: .bottomLeading) { categoryBadge }
        .overlay(alignment: .bottomTrailing) { annotationBadge }
        .overlay(alignment: .topTrailing) { favoriteButton }
        // 选中描边外扩，不压缩略图本身。
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: DS.radiusCard + 3)
                    .strokeBorder(Color.accentColor, lineWidth: 2.5)
                    .padding(-DS.s1)
            }
        }
        .shadow(
            color: shadowColor,
            radius: isHovering ? 7 : 3,
            y: 2
        )
        .scaleEffect(isHovering && !isSelected ? 1.015 : 1)
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .animation(.easeOut(duration: 0.12), value: isSelected)
    }

    /// 描边随深浅色分流：深色描边是唯一的悬停反馈来源之一，悬停升到 0.18；
    /// 浅色有阴影帮忙，维持原来的 0.25。
    private var strokeOpacity: Double {
        if colorScheme == .dark {
            return isHovering ? 0.18 : 0.08
        }
        return isHovering ? 0.25 : 0.08
    }

    /// 浅色小阴影撑层次；深色去阴影（层次交给描边 + 提亮）。
    private var shadowColor: Color {
        colorScheme == .dark
            ? .clear
            : .black.opacity(isHovering || isSelected ? 0.16 : 0.08)
    }

    /// 悬停浮条：像素尺寸。半透明材质垫底，从底边浮入。
    @ViewBuilder
    private var dimensionBar: some View {
        if showsDimensions {
            Text("\(shot.pixelWidth) × \(shot.pixelHeight)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.vertical, DS.s1)
                .frame(maxWidth: .infinity)
                .background(.ultraThinMaterial)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    /// 左下角分类胶囊。尺寸浮条出现时让位，避免底边挤成一团。
    @ViewBuilder
    private var categoryBadge: some View {
        if let category, !showsDimensions {
            Text(category)
                .font(.caption2)
                .padding(.horizontal, DS.s2)
                .padding(.vertical, 2)
                .background(.thinMaterial, in: Capsule())
                .padding(DS.s2)
                .transition(.opacity)
        }
    }

    /// 右下角标注角标：修订数 > 1（真的画过）才出现。
    @ViewBuilder
    private var annotationBadge: some View {
        if isAnnotated && !showsDimensions {
            Image(systemName: "pencil")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(DS.s1)
                .background(.thinMaterial, in: Circle())
                .padding(DS.s2)
                .transition(.opacity)
                .help("已标注")
        }
    }

    /// 悬停浮出星形按钮；已收藏则常显实心黄星。材质圆底 + ≥32pt 热区。
    @ViewBuilder
    private var favoriteButton: some View {
        if isHovering || isFavorite {
            Button(action: onToggleFavorite) {
                ZStack {
                    Circle()
                        .fill(.ultraThinMaterial)
                        .frame(width: 24, height: 24)
                    Image(systemName: isFavorite ? "star.fill" : "star")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(isFavorite ? .yellow : .primary)
                        .symbolEffect(.bounce, value: isFavorite)
                }
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(DS.s1)
            .help(isFavorite ? "取消收藏" : "收藏")
        }
    }

    private var caption: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(shot.appName ?? "未知 App")
                .font(.caption.weight(.medium))
                .lineLimit(1)
            Text(shot.capturedAt, format: .dateTime.month().day().hour().minute())
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 2)
    }
}
