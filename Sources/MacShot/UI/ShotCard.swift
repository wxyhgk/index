import SwiftUI
import UniformTypeIdentifiers

// MARK: - 卡片
//
// 网格里的一张缩略图（悬停抬升、选中蓝框 + 勾选徽章、收藏星、分类胶囊、标注角标），
// 以及它拖出去时用的 Transferable 载荷（对外一份成品 PNG / 对内一串截图 ID）。
//
// ⚠️ 结构在 2026-07 的改版里变了：**卡片没有卡面了**。
// 以前是「一整块表面（缩略图 + 文字条）走 spatialCard：填充 + 描边 + 阴影」，
// 现在是设计稿的样子 —— 图片直接浮在窗口深底上，文字是图下方的裸文字，
// 卡片级的填充 / 描边 / 阴影全部取消。三条收益，都不是纯审美：
//   · 每张卡少一次 `.shadow()` 的离屏合成（几百张时这是最贵的一项）；
//   · 深色下本来就该靠亮度分层，而一块 `white 0.045` 的卡面压在 #0D0D0F 上
//     只是把缩略图周围糊一圈灰，读不出高度；
//   · 缩略图不再需要为「露出一圈卡面」而内缩 4pt，瀑布模式的等宽贴合更准。
// 深度线索只剩两件，也够了：缩略图边缘那条渐变发丝线（“边缘比表面重要”），
// 和悬停时的 1.02 / −3pt 抬升。

extension UTType {
    /// 应用内截图引用（一串截图 ID）。反向域名与 bundle id `com.wxyhgk.macshot` 对齐，
    /// 已在 `Resources/Info.plist` 的 `UTExportedTypeDeclarations` 里声明为导出类型 ——
    /// 没有声明的话 `UTType(exportedAs:)` 只能拿到一个动态类型，跨进程识别不可靠。
    static let macShotShotIDs = UTType(exportedAs: "com.wxyhgk.macshot.shot-ids")
}

/// 应用内拖拽的轻量载荷：**只有一串截图 ID**，没有图像、没有查库。
/// 侧边栏「拖到标签上打标签」用 `.dropDestination(for: ShotIDPayload.self)` 接它，
/// 拿到 ID 之后自己去 `ShotStore` 取需要的东西 —— 拖拽全程一张图都不解码。
///
/// 用 `Set` 而不是 `Array`：选中集合本身就是 `Set<Int64>`，直接拷进来是一次
/// COW 引用拷贝（O(1)），选中 5000 张和选中 1 张的构造成本一样；
/// 打标签本来也是集合语义，不关心顺序。
struct ShotIDPayload: Codable, Transferable {
    let shotIDs: Set<Int64>

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .macShotShotIDs)
    }
}

/// 拖出卡片的载荷。构造只是拷一个 Shot 值 + 一个 ID 集合的引用 —— 渲染含标注的成品 PNG
/// 发生在**接收方真正收文件时**（FileRepresentation 的导出闭包），
/// 目录复用暂存栏的拖拽临时目录，下次启动统一清理；渲染失败退回原图路径。
struct ShotDragFile: Transferable {
    let shot: Shot
    /// 应用内接收方要用的 ID 集合：被拖的卡片在多选集合里 → 全部选中项，
    /// 不在 → 只有它自己（Finder 的行为）。由 `GalleryGrid.dragFile(for:)` 组装，
    /// 取的是内存里的 `GallerySelection.shared.selectedIDs`，不落盘不查库。
    let shotIDs: Set<Int64>

    static var transferRepresentation: some TransferRepresentation {
        // 次序即优先级。PNG 文件表示必须排在最前：外部 App（访达 / 聊天窗口 / 邮件）
        // 按自己支持的类型挑第一个能用的，排后面会被应用内的 ID 类型抢走语义。
        FileRepresentation(exportedContentType: .png) { file in
            let url = await MainActor.run { file.writeRenderedPNG() }
            return SentTransferredFile(url, allowAccessingOriginalFile: true)
        }
        // 应用内表示：只是把已经攥在手里的 ID 集合换个类型，闭包里没有解码 / 查库 / 渲染。
        //
        // ⚠️ 取舍：**外部拖出仍然只导出被拖的那一张**（上面 FileRepresentation 用的 `shot`）。
        //    多选一次拖出多个 PNG 需要换掉 `.draggable(_:)` 这个单 item 接口，
        //    是一个独立功能，本次不做 —— 因此「多选」目前只影响应用内这条 ID 通道。
        ProxyRepresentation(exporting: { ShotIDPayload(shotIDs: $0.shotIDs) })
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

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var isHovering = false
    /// 悬停 0.3s 后才浮出尺寸条 —— 快速扫过不打扰。
    @State private var showsDimensions = false

    // 刻意不用 @ObservedObject 订阅 store —— 只需要一个文件路径，
    // 订阅了会导致任何 store 变化都重建全部缩略图。
    private var thumbnailURL: URL { ShotStore.shared.thumbnailURL(for: shot) }

    var body: some View {
        // 单元格 = 缩略图 + 图下方左对齐的两行文字。s2 的间隙：卡面取消之后
        // 图和字之间没有「卡片内缩」帮忙撑开了，得自己留出这一档。
        VStack(alignment: .leading, spacing: DS.s2) {
            thumbnail
            caption
        }
        // 热区跟着单元格形状走，四个角外的三角区不再吃点击。
        .contentShape(cellShape)
        // ⚠️ 悬停判定必须挂在形变（scale 1.02 / offset −3）**之前**：
        // 挂在形变之后，卡片一悬停就上移，底边下的指针会掉出热区 →
        // 「悬停→位移→脱离→复位→再悬停」的自激抖动。
        //（以前这条形变在 `spatialCard` 里，现在写在本文件下面几行，约束不变。）
        .onHover { isHovering = $0 }
        // 选中框包住**整个单元格**（含文字），所以画在这一层而不是缩略图上。
        // 放在形变之前 = 框跟着卡片一起抬升，不会在悬停时和内容错开。
        .overlay { selectionRing }
        // 四态形变。缩放只受悬停控制、选中只加框 —— 两者正交，
        // 「选中」和「鼠标在这张上」必须能同时读出（HIG：焦点与选中各自独立可见）。
        //
        // ⚠️ 这里**没有** `.shadow()`：卡片没有卡面，也就没有可投影的表面。
        // 深色下阴影落在 #0D0D0F 上读不出高度（那是亮度阶梯的活），
        // 而每卡一次阴影就是每卡一次离屏合成 —— 几百张时这是最贵的一项。
        // 抬升的可读性由缩略图边缘那条 rim 在悬停时加浓来补（见 `thumbnailRim`）。
        .scaleEffect(scaleValue)
        .offset(y: isHovering && !reduceMotion ? DS.Lift.hoverY : 0)
        .animation(DS.Motion.micro(reduced: reduceMotion), value: isHovering)
        .animation(DS.Motion.micro(reduced: reduceMotion), value: isPressed)
        .animation(DS.Motion.standard(reduced: reduceMotion), value: isSelected)
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

    private var scaleValue: CGFloat {
        if isPressed { return DS.Lift.pressScale }
        return isHovering ? DS.Lift.hoverScale : 1
    }

    /// 圆角 10（`DS.radiusCard`，设计稿 §4 明确的那一档）。两个用途共用一份：
    /// 缩略图的裁切/填充/描边，以及整个单元格的点击热区（`cellShape`）。
    ///
    /// 卡面取消之后不再有「外圆角 − 内缩」的同心换算要做 —— 图片自己就是最外层，
    /// 唯一还要同心的是选中框（见 `selectionRing`：10 + 2 = 12）。
    private var thumbShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous)
    }

    /// 单元格热区。和缩略图同一个圆角：真正需要削掉的是**顶部**那两个角外的
    /// 三角区（那里视觉上是圆的、却会吃到点击），底部两角在文字下方，
    /// 削或不削肉眼无差 —— 用同一个形状换来的是「只有一处圆角常量」。
    private var cellShape: RoundedRectangle { thumbShape }

    private var thumbnail: some View {
        ZStack {
            // 衬底必须**比窗底亮**，否则卡片读起来是「洞」不是「块」。
            // 浅色下 `.quaternary` 比 windowBackgroundColor 还暗，是浅色主题
            // 显脏的根源（见 DS.thumbnailBacking 的注释）。
            thumbShape.fill(DS.thumbnailBacking(scheme))
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
        .clipShape(thumbShape)
        .overlay { thumbnailRim }
        // 四个角各一件，互不重叠（徽章与收藏星的位置安排见 favoriteButton 的注释）。
        .overlay(alignment: .topLeading) { favoriteButton }
        .overlay(alignment: .topTrailing) { selectionBadge }
        .overlay(alignment: .bottomLeading) { categoryBadge }
        .overlay(alignment: .bottomTrailing) { annotationBadge }
        // rim 在深色下走 `.plusLighter`，混合模式**必须**有 compositingGroup 做边界，
        // 否则它会和任意兄弟视图混合 —— 在网格里就是和邻居卡片混。
        // 官方说法是这个修饰器「开销极小，只重排效果的应用时机，不做栅格化」，
        // 和被禁的 `drawingGroup()` 不是一回事。
        .compositingGroup()
        // 浅色下**只给悬停中的那一张**加阴影。
        //
        // 深色靠亮度阶梯 + rim 加浓就能读出抬升，浅色不行：白底上一条深色 rim
        // 读起来是「描了个边」而不是「浮起来了」，抬升感全靠阴影。
        // 而「每卡一次阴影 = 每卡一次离屏合成」的性能红线依然成立 ——
        // 所以只给悬停那一张：同一时刻至多一张卡付这个代价。
        .shadow(
            color: hoverShadow.color,
            radius: hoverShadow.radius,
            y: hoverShadow.y
        )
        // 角标出没 + rim 加浓：悬停走 micro，选中走 standard。
        .animation(DS.Motion.micro(reduced: reduceMotion), value: isHovering)
        .animation(DS.Motion.standard(reduced: reduceMotion), value: isSelected)
    }

    /// 悬停阴影。浅色悬停时给一档 `.raised`；其余情况（含深色的任何状态）
    /// 一律 `.none` —— 深色下的黑阴影落在近黑底上读不出高度，只是白付一次离屏。
    private var hoverShadow: DS.Shadow {
        guard scheme != .dark, isHovering else { return .none }
        return DS.shadow(.raised, scheme)
    }

    /// 缩略图边缘的渐变发丝线。**卡面取消之后它是唯一的常驻深度线索**，
    /// 也是「深色的暗截图不至于糊进 #0D0D0F 的窗底」的唯一保证 ——
    /// 设计稿说的「没有外框」指的是没有卡片框，不是让图片边界消失。
    ///
    /// 常态取 `.content` 那一档（深色 顶 0.14 / 底 0.035），悬停切到 `.raised`
    /// 且带 hovering 加浓（深色 顶 0.28 / 底 0.05）—— 抬起来的表面接光更多，
    /// 边缘对比理应更强。这比给悬停加一层阴影更省，也更准（深色阴影读不出）。
    private var thumbnailRim: some View {
        let rim = DS.rim(isHovering ? .raised : .content, scheme, hovering: isHovering)
        return thumbShape
            .strokeBorder(rim.gradient, lineWidth: rim.lineWidth)
            .blendMode(reduceTransparency ? .normal : rim.blend)
            .allowsHitTesting(false)
    }

    /// 选中框：包住整个单元格的 2px 强调蓝圆角框，外扩 2pt（设计稿 §4）。
    ///
    /// 同心换算走 `DS.radiusOuter`：外扩量和圆角增量必须是**同一个数**，
    /// 所以框圆角 = 缩略图 10 + 外扩 2 = 12，「比缩略图大一档」正是这么来的。
    /// 2px 是 WCAG 2.4.13 Focus Appearance 的下限，也是 1x 屏上不发虚的宽度。
    ///
    /// 这里**不再**画 `spatialCard` 那套「光晕 + accent 色调」：
    ///   · 色调是垫在卡面上的染色玻璃，没有卡面就等于直接染在缩略图上 —— 脏；
    ///   · 光晕是一次 `.blur(9)`，只为「更醒目」而付一次离屏渲染，
    ///     而 2px 实框 + 右上角 22pt 实心徽章在密集网格里已经一眼可辨。
    @ViewBuilder
    private var selectionRing: some View {
        if isSelected {
            RoundedRectangle(
                cornerRadius: DS.radiusOuter(inner: DS.radiusCard, offset: DS.Glow.ringOffset),
                style: .continuous
            )
            .strokeBorder(
                Color.accentColor.opacity(DS.Glow.ringOpacity(scheme)),
                lineWidth: DS.Glow.ringWidth
            )
            .padding(-DS.Glow.ringOffset)
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }

    /// **右上角**勾选徽章：直径 22 的强调蓝实心圆 + 白勾（设计稿 §4，旧版在左上角）。
    ///
    /// 为什么框之外还要一个徽章：多选时密集网格里全是相邻的蓝框，边框会互相淹没，
    /// 徽章才是「一眼数出选了几张」的那个线索（Photos / Google Photos / Windows 一致）。
    ///
    /// 实心 accent 圆盘直接压在缩略图上，所以补一圈 1pt 白色发丝环：
    /// 截图内容本身就可能是一片蓝（浏览器、系统设置），没有这圈分隔环，
    /// 徽章会和背景糊成一块。不用材质圆底（旧版那样）—— 设计稿要的是实心，
    /// 而实心正好也省掉这一件小材质。徽章不参与点击（选中由父级的点击手势负责）。
    @ViewBuilder
    private var selectionBadge: some View {
        if isSelected {
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Color.accentColor, in: Circle())
                .overlay {
                    Circle().strokeBorder(.white.opacity(0.7), lineWidth: 1)
                }
                // s2 = 8：与左上角收藏星的可视圆心内缩（4pt padding + 32pt 热区里
                // 那颗 24pt 圆）对齐，两个角上的圆看起来在同一条内缩线上。
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

    /// **左上角**收藏星：悬停浮出，已收藏则常显实心黄星。材质圆底 + ≥32pt 热区。
    ///
    /// 从右上角搬到左上角，因为设计稿把勾选徽章放在了右上角，两者会重叠。
    /// 三种排法里选了这个：
    ///   · ~~星留在右上、选中时让位~~ —— 选中一张就点不到它的收藏星，
    ///     而「先选中再收藏」恰好是最常走的路径；
    ///   · ~~星挪到右上角偏下~~ —— 位置会随选中态跳动，肌肉记忆全废；
    ///   · **星固定左上角** —— 位置永不变动，和右上的徽章、左下的分类胶囊、
    ///     右下的标注角标各占一角，四件互不重叠，也不需要任何条件让位。
    /// 代价是左上角这颗星比旧版更显眼一点（它现在压在图片的左上而不是右上），
    /// 但它本来就只在悬停或已收藏时出现，不是常驻噪音。
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

    /// 缩略图下方左对齐的两行：App 名 12pt / 时间 11pt 灰（设计稿 §4）。
    ///
    /// 字号写死而不是用 `.caption`/`.caption2`：那两档在 macOS 上都是 10pt，
    /// 设计稿给的是 12/11 —— 文字从卡面上搬到画布上之后确实需要大一档才压得住，
    /// 而 DS 头部那份「卡片主行用 .caption」的字阶约定就是为「字在卡面上」写的。
    /// 冲突处以设计稿为准（redesign-target 开头的规矩）。
    ///
    /// **水平内缩 0**：图片就是单元格的左边界，文字要和它对在同一条竖线上。
    /// 字形本身的左边距（left side bearing）会让文字看起来正好比图片边缘退进
    /// 半个像素 —— 这是光学对齐想要的结果，再加 padding 就成了明显的缩进。
    private var caption: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(shot.appName ?? "未知 App")
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
            Text(shot.capturedAt, format: .dateTime.month().day().hour().minute())
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        // 底部留 s1：选中框外扩 2pt 画在单元格外沿，这 4pt 让它不至于贴着字底。
        .padding(.bottom, DS.s1)
    }
}
