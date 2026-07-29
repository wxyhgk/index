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
    /// 按下态（四态之外的第五态，缩放 0.99）。**唯一由外部驱动的状态**：
    /// 点击 / 双击 / `.draggable` 三个手势全挂在父级 GalleryGrid 上，卡片内部再挂一个
    /// `DragGesture(minimumDistance: 0)` 去嗅探按下，会和 `.draggable` 的拖拽识别器抢事件 ——
    /// 拖出是核心功能，不拿它赌一个按压反馈。默认 false：父级哪天接上按下手势，
    /// 传这一个参数即可，卡片这边不用改。
    var isPressed: Bool = false
    let onToggleFavorite: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false
    /// 悬停 0.3s 后才浮出尺寸条 —— 快速扫过不打扰。
    @State private var showsDimensions = false

    // 刻意不用 @ObservedObject 订阅 store —— 只需要一个文件路径，
    // 订阅了会导致任何 store 变化都重建全部缩略图。
    private var thumbnailURL: URL { ShotStore.shared.thumbnailURL(for: shot) }

    /// 卡片四态。缩放只受悬停控制、选中只加光 —— 两者正交，
    /// 「选中」和「鼠标在这张上」必须能同时读出（HIG：焦点与选中各自独立可见）。
    private var cardState: SpatialCardState {
        SpatialCardState(isHovering: isHovering, isSelected: isSelected, isPressed: isPressed)
    }

    var body: some View {
        // spacing 用 s1：缩略图自己已经内缩了 s1，两段相加正好是 s2 的视觉间隙。
        VStack(alignment: .leading, spacing: DS.s1) {
            thumbnail
            caption
        }
        // 热区跟着卡片形状走，四个角外的三角区不再吃点击。
        .contentShape(RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous))
        // ⚠️ 悬停判定必须挂在 spatialCard（scale 1.02 / offset −3）**之前**：
        // 挂在形变之后，卡片一悬停就上移，底边下的指针会掉出热区 →
        // 「悬停→位移→脱离→复位→再悬停」的自激抖动。
        .onHover { isHovering = $0 }
        // 表面填充 / 边缘高光 / 阴影 / 选中环 + 光晕 + 色调 / 四态动效，一次给全。
        // 卡片背景是纯填充 + 描边，**没有任何 Material** —— 内容层不上玻璃，
        // 也是性能红线（每张卡一个 NSVisualEffectView 必炸）。
        .spatialCard(cardState)
        .task(id: isHovering) {
            guard isHovering else {
                showsDimensions = false
                return
            }
            try? await Task.sleep(for: .seconds(0.3))
            guard !Task.isCancelled else { return }
            // 浮条出没属于微交互，和角标同档；Reduce Motion 下自动收紧成 easeOut。
            withAnimation(DS.Motion.micro(reduced: reduceMotion)) { showsDimensions = true }
        }
    }

    /// 缩略图内圆角 = 卡片外圆角 10 − 内缩 s1(4) = 6（正好落在 radiusSmall 上）。
    /// 同心才能让缩略图与卡片边缘的缝隙在整圈上恒定 —— 不同心的话拐角处会被
    /// 「掐细」或张成喇叭口，那种视觉张力就是廉价感的来源。
    private var innerShape: RoundedRectangle {
        RoundedRectangle(
            cornerRadius: DS.radiusInner(outer: DS.radiusCard, inset: DS.s1),
            style: .continuous
        )
    }

    private var thumbnail: some View {
        ZStack {
            innerShape.fill(.quaternary.opacity(0.5))
            CachedImage(url: thumbnailURL, key: shot.sha256)
                // 视差只给当前悬停的那张卡开：未悬停时 unit vector 是 .zero，
                // `.visualEffect` 闭包退化成 identity 变换，成本近似为零。
                // 幅度（±5pt / ±1.5° / perspective 0.3）在 DS.Parallax 里，
                // Reduce Motion 由修饰器自己整个关掉（不是减半）。
                .parallaxThumbnail(isEnabled: isHovering)
        }
        .frame(height: height)
        // 尺寸浮条盖在底边，先叠再裁 —— 让浮条跟着缩略图圆角走。
        .overlay(alignment: .bottom) { dimensionBar }
        .clipShape(innerShape)
        .overlay(alignment: .topLeading) { selectionBadge }
        .overlay(alignment: .bottomLeading) { categoryBadge }
        .overlay(alignment: .bottomTrailing) { annotationBadge }
        .overlay(alignment: .topTrailing) { favoriteButton }
        // 内缩 s1：卡片表面在缩略图四周露出一圈，深度才有落脚点。
        .padding(DS.s1)
        // 只剩角标出没需要动画（描边/阴影/缩放/选中环都归 spatialCard 管了）：
        // 悬停角标走 micro，选中角标走 standard —— 替换掉原来的两条 .easeOut(0.12)。
        .animation(DS.Motion.micro(reduced: reduceMotion), value: isHovering)
        .animation(DS.Motion.standard(reduced: reduceMotion), value: isSelected)
    }

    /// 左上角选中角标。图块选中的通用解是「发光环 + 角标」（Photos / Google Photos / Windows 一致）：
    /// 多选时密集网格里的光环容易被邻居的环淹没，角标才是一眼可数的那个线索。
    ///
    /// 尺寸复用 favoriteButton 的约定：24pt 材质圆底（材质只出现在这种小件上，
    /// 卡片表面依然零材质），净内缩 8pt 与右上角的星形对称。
    /// palette 渲染让「白勾 + accent 圆盘」两层分开上色 —— 单色模式下勾是镂空的，
    /// 落在亮缩略图上会糊掉。角标不参与点击（选中由父级的点击手势负责）。
    @ViewBuilder
    private var selectionBadge: some View {
        if isSelected {
            ZStack {
                Circle()
                    .fill(.ultraThinMaterial)
                    .frame(width: 24, height: 24)
                Image(systemName: "checkmark.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color.accentColor)
                    // 18pt：比 24pt 圆底小一圈，留出材质做「光晕」，边缘不至于齐平割手。
                    .font(.system(size: 18, weight: .semibold))
            }
            .frame(width: 24, height: 24)
            .padding(DS.s2)
            .transition(.scale(scale: 0.6).combined(with: .opacity))
            .allowsHitTesting(false)
        }
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
        // 文字现在长在卡片表面上（不再是卡片外的裸文字），得有自己的内缩：
        // 水平 s2 比缩略图的 s1 多 4pt —— 文字的视觉左边界在字形之外，
        // 和图像同数内缩会显得往外顶。底部同样 s2，与顶部（s1 + 卡片圆角）配平。
        .padding(.horizontal, DS.s2)
        .padding(.bottom, DS.s2)
    }
}
