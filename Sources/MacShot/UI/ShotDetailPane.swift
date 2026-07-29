import SwiftUI

// MARK: - 右侧详情
//
// 单选时 inspector 里的那一栏：预览、动作区（编辑 / 收藏 / 钉图 / 导出 + 更多菜单）、
// 敏感内容横幅与一键打码、来源 / 识别 / 标签 / 修订历史四张分组卡片，
// 以及修订历史的单行视图与它的展示用快照类型。

/// 修订的展示用快照。避免在 body 里反复解 layersJSON。
private struct RevisionSummary: Identifiable {
    let id: Int64
    let version: Int
    let note: String
    let layerCount: Int
    let createdAt: Date
}

// 关于材质：整栏**故意不加任何材质**。`.inspector` 已经自动套好了详情栏材质，
// 这里再叠一层就是「材质叠材质」；同理栏内的信息卡只能用 `.quaternary` 这类
// 半透明填充，绝不能放 Material（§4.2 末行）。
struct ShotDetailPane: View {
    let shot: Shot

    // 订阅 store 是为了收藏态实时刷新；重查询都挂在 task(id:) 上，不受影响。
    @ObservedObject private var store = ShotStore.shared
    @ObservedObject private var selection = GallerySelection.shared
    /// 阴影要按外观分流：深色下 L1 的阴影是 `.none`（黑底上的黑阴影只是糊一层脏）。
    @Environment(\.colorScheme) private var scheme

    /// 修订历史只在切换截图 / 关闭编辑器时查一次数据库，不再挂在 body 上。
    @State private var revisions: [RevisionSummary] = []
    /// 派生属性同理，切换截图时查一次。
    @State private var category: String?
    /// 目标是否已有特征指纹。没有就先禁用「相似」——刚截的图可能还在后台分析。
    @State private var hasFeaturePrint = false
    @State private var showingSimilar = false
    /// 同源截图数量（含自己）。切换截图时查一次，少于 2 张禁用时间线入口。
    @State private var relatedCount = 0
    @State private var showingTimeline = false
    /// 敏感内容检测结果（后台异步落库，和指纹一样随 store 刷新重查）。
    @State private var sensitiveRegions: [SensitiveRegion] = []
    /// 是否已打码。加载时按「最新修订的马赛克层是否盖住全部命中区域」判定，
    /// 一键打码完成后直接置真。
    @State private var sensitiveMasked = false
    /// 录屏锚点：这张截图是某段录屏的首帧时，`recording.path` 属性存着 mp4 路径。
    @State private var recordingPath: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.s3) {
                preview
                actions
                if let recordingPath {
                    openRecordingButton(path: recordingPath)
                }
                if !sensitiveRegions.isEmpty {
                    sensitiveBanner
                }
                sourceCard
                // TagSection 插槽：标签分支（feat/tags）会在来源和识别之间
                // 插入单选详情的标签行。
                recognitionCard
                TagSection(shot: shot)
                historyCard
            }
            .padding(DS.s4)
        }
        .task(id: shot.id) {
            loadRevisions()
            category = shot.id.flatMap { store.attributeText(shotID: $0, key: AttributeKey.category) }
            refreshFeaturePrint()
            refreshSensitiveRegions()
            relatedCount = store.relatedShots(to: shot).count
            // 路径存在 payload 里（不进全文索引），这里转回字符串。
            recordingPath = shot.id
                .flatMap { store.attributePayload(shotID: $0, key: AttributeKey.recordingPath) }
                .flatMap { String(data: $0, encoding: .utf8) }
        }
        // 指纹由后台分析异步补上：store 每次刷新（属性落库会触发 reload）都重查一次。
        // 属性写入不一定改变 shots 数组本身，所以订阅 objectWillChange 而不是 onChange。
        // 单行 LIMIT 1 查询，代价可忽略。
        // 修订列表同理：编辑器是同一窗口内的模式分支（非模态 sheet），保存时机
        // 不再有「sheet 收起」这样的锚点 —— appendRevision 落库会发布变更，这里重查。
        .onReceive(store.objectWillChange) { _ in
            refreshFeaturePrint()
            refreshSensitiveRegions()
            loadRevisions()
        }
        .sheet(isPresented: $showingSimilar) {
            SimilarShotsSheet(shot: shot)
        }
        .sheet(isPresented: $showingTimeline) {
            TimelineSheet(shot: shot)
        }
    }

    /// 录屏首帧锚点的「打开录像」：用系统默认播放器打开 mp4。
    /// 视频文件被用户删掉时按钮禁用（锚点截图还在，历史不丢）。
    private func openRecordingButton(path: String) -> some View {
        Button {
            SystemNavigator.open(url: URL(fileURLWithPath: path))
        } label: {
            Label("打开录像", systemImage: "play.rectangle")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(!FileManager.default.fileExists(atPath: path))
        .help(path)
    }

    private func refreshFeaturePrint() {
        hasFeaturePrint = shot.id.map {
            store.attributePayload(shotID: $0, key: AttributeKey.featurePrint) != nil
        } ?? false
    }

    private func refreshSensitiveRegions() {
        guard let id = shot.id,
              let data = store.attributePayload(shotID: id, key: AttributeKey.sensitiveRegions),
              let regions = try? JSONDecoder().decode([SensitiveRegion].self, from: data),
              !regions.isEmpty
        else {
            sensitiveRegions = []
            sensitiveMasked = false
            return
        }
        sensitiveRegions = regions
        // 已打码 = 最新修订里每个命中区域都被某个马赛克层完整覆盖。
        let pixelates = (store.latestRevision(for: shot)?.layers ?? [])
            .filter { $0.kind == .pixelate }
        sensitiveMasked = regions.allSatisfy { region in
            pixelates.contains { $0.rect.cg.contains(region.rect) }
        }
    }

    /// 按种类汇总的提示文案，如「2 处邮箱、1 处 API 密钥」。
    private var sensitiveSummary: String {
        var order: [String] = []
        var counts: [String: Int] = [:]
        for region in sensitiveRegions {
            if counts[region.kind] == nil { order.append(region.kind) }
            counts[region.kind, default: 0] += 1
        }
        return order.map { "\(counts[$0] ?? 0) 处\($0)" }.joined(separator: "、")
    }

    private var sensitiveBanner: some View {
        VStack(alignment: .leading, spacing: DS.s2) {
            HStack(alignment: .firstTextBaseline, spacing: DS.s2) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("检测到敏感内容：\(sensitiveSummary)")
                    .font(.caption.weight(.semibold))
            }
            Text(sensitiveRegions.map(\.preview).joined(separator: " · "))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(3)
            if sensitiveMasked {
                Label("已打码", systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.green)
            } else {
                Button {
                    maskSensitiveRegions()
                } label: {
                    Label("一键打码", systemImage: "squareshape.split.3x3")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(DS.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        // 警示色（黄）是状态语义，不是强调色也不参与深度表达 —— 保持。
        // 圆角统一补 .continuous。
        .background(
            RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous)
                .fill(Color.yellow.opacity(0.18))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous)
                .strokeBorder(Color.yellow.opacity(0.5), lineWidth: 1)
        )
    }

    /// 一键打码：每个命中区域外扩 4px 生成一个马赛克层，
    /// 追加为**新修订**（非破坏，历史可回溯，随时能回到打码前）。
    private func maskSensitiveRegions() {
        let existing = store.latestRevision(for: shot)?.imageLayers ?? Layers()
        var layers = existing
        let bounds = CGRect(
            x: 0, y: 0,
            width: CGFloat(shot.pixelWidth), height: CGFloat(shot.pixelHeight)
        )
        for region in sensitiveRegions {
            let rect = region.rect.insetBy(dx: -4, dy: -4).intersection(bounds)
            guard !rect.isNull, !rect.isEmpty else { continue }
            layers.append(Layer(kind: .pixelate, rect: LRect(rect)))
        }
        guard store.appendRevision(shot: shot, layers: layers, note: "自动脱敏") != nil else { return }
        sensitiveMasked = true
        loadRevisions()
    }

    private func loadRevisions() {
        revisions = store.revisions(for: shot).enumerated().map { index, rev in
            RevisionSummary(
                id: rev.id ?? Int64(index),
                version: index + 1,
                note: rev.note ?? "编辑",
                layerCount: rev.layers.count,
                createdAt: rev.createdAt
            )
        }
    }

    private var preview: some View {
        // 预览图是详情栏里的 L1 内容层：单层阴影，数值走 DS.shadow 统一出数
        // （浅色 black .07/r3/y1，深色 .none）—— 旧的 0.12/r4/y2 是魔法数，
        // 且在深色下会在材质上糊出一圈黑。
        let sh = DS.shadow(.content, scheme)
        return CachedImage(url: store.thumbnailURL(for: shot), key: shot.sha256)
            .clipShape(RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous))
            .shadow(color: sh.color, radius: sh.radius, y: sh.y)
            .contentShape(Rectangle())
            .onTapGesture { QuickLookController.shared.present() }
            .help("点击（或按空格）用 Quick Look 预览原图")
    }

    /// 动作区一行放完：「编辑」主按钮 + 收藏/钉图/导出 icon-only，
    /// 低频动作（出处/相似/时间线/Bug 报告/上传）收进「更多」菜单。
    private var actions: some View {
        HStack(spacing: DS.s2) {
            Button {
                GalleryWindowMode.shared.openEditor(shotID: shot.id)
            } label: {
                Label("编辑", systemImage: "pencil.tip.crop.circle")
            }
            .buttonStyle(.borderedProminent)

            let favorited = shot.id.map(store.isFavorite) ?? false
            Button {
                store.toggleFavorite(shot)
            } label: {
                Label(favorited ? "取消收藏" : "收藏", systemImage: favorited ? "star.fill" : "star")
                    .foregroundStyle(favorited ? Color.yellow : Color.primary)
            }
            .labelStyle(.iconOnly)
            .help(favorited ? "取消收藏" : "收藏")

            Button {
                pin()
            } label: {
                Label("钉图", systemImage: "pin")
            }
            .labelStyle(.iconOnly)
            .help("钉在桌面")

            Button {
                export()
            } label: {
                Label("导出", systemImage: "square.and.arrow.up")
            }
            .labelStyle(.iconOnly)
            .help("导出成品（含标注）")

            Spacer(minLength: 0)

            moreMenu
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private var moreMenu: some View {
        Menu {
            Button {
                openSource()
            } label: {
                Label("回到出处", systemImage: "arrow.up.forward.app")
            }
            .disabled(shot.sourceURL == nil && shot.appBundleID == nil)

            Button {
                showingSimilar = true
            } label: {
                Label("查找相似", systemImage: "sparkles.rectangle.stack")
            }
            .disabled(!hasFeaturePrint)

            Button {
                showingTimeline = true
            } label: {
                Label("同源时间线", systemImage: "clock.arrow.circlepath")
            }
            .disabled(relatedCount < 2)

            Divider()

            Button {
                Clipboard.copy(text: BugReport.markdown(
                    shot: shot,
                    pixelWidth: shot.pixelWidth,
                    pixelHeight: shot.pixelHeight
                ))
            } label: {
                Label("复制 Bug 报告", systemImage: "ladybug")
            }

            Button {
                upload()
            } label: {
                Label("上传图床", systemImage: "arrow.up.circle")
            }
            .disabled(
                AppSettings.shared.uploadEndpoint
                    .trimmingCharacters(in: .whitespaces).isEmpty
            )
        } label: {
            Label("更多", systemImage: "ellipsis.circle")
        }
        .labelStyle(.iconOnly)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("更多动作：出处 / 相似 / 时间线 / Bug 报告 / 上传")
    }

    /// 钉在桌面：走注册表的 pin 动作（界面层不直接建窗口），材料从图库记录重建。
    private func pin() {
        guard let base = store.originalImage(for: shot) else { return }
        let context = CaptureContext(
            base: base,
            layers: store.latestRevision(for: shot)?.imageLayers ?? Layers(),
            shot: shot,
            region: nil,
            host: nil
        )
        Task { try? await CaptureActionRegistry.shared.action(id: ActionID.pin)?.perform(context) }
    }

    /// 上传图床：复用截图工具条的 UploadAction，材料从图库记录重建。
    private func upload() {
        guard let base = store.originalImage(for: shot) else { return }
        let context = CaptureContext(
            base: base,
            layers: store.latestRevision(for: shot)?.imageLayers ?? Layers(),
            shot: shot,
            region: nil,
            host: nil
        )
        Task {
            do {
                try await UploadAction().perform(context)
            } catch {
                AppAlert.error(
                    "上传失败",
                    error: error,
                    host: GalleryWindowController.shared.window
                )
            }
        }
    }

    /// 回到出处：优先开网址（默认浏览器），否则激活来源 App。
    private func openSource() {
        if let source = shot.sourceURL, let url = URL(string: source) {
            SystemNavigator.open(url: url)
        } else if let bundleID = shot.appBundleID {
            SystemNavigator.activateApp(bundleID: bundleID)
        }
    }

    // MARK: - 信息分组卡片

    /// 分组卡片：quaternary 底 + 卡片圆角 + caption.semibold 组题。
    ///
    /// 底色**只能是 `.quaternary`，不能换成 Material**：详情栏本身已经站在
    /// inspector 材质上了，卡片再上材质就是玻璃叠玻璃，两层模糊互相采样，
    /// 结果是浑浊而不是更透。
    /// 同心圆角：外 10、内缩 s3(12) → 内层 = −2 → 归零，所以卡内元素一律直角
    /// （见 RevisionRow）。这正是公式该给出的答案，不是偷懒。
    private func card(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: DS.s2) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
        .padding(DS.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            .quaternary.opacity(0.5),
            in: RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous)
        )
    }

    private var sourceCard: some View {
        card("来源") {
            row("App", shot.appName)
            row("Bundle ID", shot.appBundleID)
            row("版本", shot.appVersion.map { v in
                shot.appBuild.map { "\(v) (\($0))" } ?? v
            })
            row("窗口标题", shot.windowTitle)
            if let url = shot.sourceURL {
                VStack(alignment: .leading, spacing: 2) {
                    Text("网址").font(.caption).foregroundStyle(.secondary)
                    Link(url, destination: URL(string: url) ?? URL(string: "about:blank")!)
                        .font(.caption)
                        .lineLimit(3)
                }
            }
            row("显示器", shot.displayName)
            row("尺寸", "\(shot.pixelWidth) × \(shot.pixelHeight) px @\(String(format: "%.0f", shot.scale))x")
            row("时间", shot.capturedAt.formatted(date: .abbreviated, time: .standard))
        }
    }

    /// 机器补出来的信息（分类、OCR）单独一组，和采集自系统的「来源」分开。
    @ViewBuilder
    private var recognitionCard: some View {
        let ocr = shot.ocrText ?? ""
        if category != nil || !ocr.isEmpty {
            card("识别") {
                row("分类", category)
                if !ocr.isEmpty {
                    DisclosureGroup("识别文字（\(ocr.count) 字）") {
                        Text(ocr)
                            .font(.caption)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, DS.s1)
                    }
                    .font(.caption)
                }
            }
        }
    }

    private var historyCard: some View {
        card("修订历史（\(revisions.count)）") {
            Text("每次编辑都追加一条记录，原图从不被修改。")
                .font(.caption2)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(revisions.enumerated()), id: \.element.id) { index, rev in
                    RevisionRow(
                        revision: rev,
                        isLatest: index == revisions.count - 1,
                        isFirst: index == 0,
                        isLast: index == revisions.count - 1
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: DS.s2) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 64, alignment: .leading)
                Text(value)
                    .font(.caption)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func export() {
        guard let base = store.originalImage(for: shot) else { return }
        let rendered = LayerRenderer.render(
            base: base,
            layers: store.latestRevision(for: shot)?.imageLayers ?? Layers()
        )
        _ = try? ImageExporter.exportWithPanel(
            rendered,
            suggestedName: ImageExporter.suggestedName(for: shot)
        )
    }
}

/// 修订历史的一行：左侧 2pt 竖线把圆点连成真时间线，行内容 hover 提亮。
private struct RevisionRow: View {
    let revision: RevisionSummary
    let isLatest: Bool
    let isFirst: Bool
    let isLast: Bool

    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .leading) {
            // 连线分上下两段等分行高，中间给圆点留 8pt；首行缺上段、末行缺下段。
            VStack(spacing: 0) {
                connector.opacity(isFirst ? 0 : 1)
                Color.clear.frame(height: 8)
                connector.opacity(isLast ? 0 : 1)
            }
            .padding(.leading, 3)

            Circle()
                .fill(isLatest ? Color.accentColor : Color.secondary.opacity(0.55))
                .frame(width: 8, height: 8)

            HStack(spacing: DS.s2) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("v\(revision.version) · \(revision.note)")
                        .font(.caption)
                    Text("\(revision.layerCount) 个图层 · \(revision.createdAt.formatted(date: .omitted, time: .shortened))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, DS.s4)
            .padding(.vertical, DS.s1)
        }
        // 同心圆角：外层信息卡 10，内缩 s3(12) → 内层 = −2 → 归零。
        // 所以这条 hover 提亮底是**直角**，不是「忘了给圆角」——
        // 在只剩 12pt 呼吸位的地方硬套 6pt 圆角，拐角处的间隙会被掐细。
        .background(
            RoundedRectangle(
                cornerRadius: DS.radiusInner(outer: DS.radiusCard, inset: DS.s3),
                style: .continuous
            )
            .fill(Color.primary.opacity(isHovering ? 0.06 : 0))
        )
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        // 悬停提亮是微交互，走 micro（0.22 是「立刻发生」的感知阈）。
        .animation(DS.Motion.micro(reduced: reduceMotion), value: isHovering)
    }

    private var connector: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.3))
            .frame(width: 2)
            .frame(maxHeight: .infinity)
    }
}
