import SwiftUI

// MARK: - 全部信息（详情面板的下钻页）
//
// 设计稿 §6.6 只画了一行「查看全部信息 ›」，没有规定它后面是什么。
// 这里的选择是**面板内下钻**而不是 sheet：
//   · 元数据是「看着图对照读」的东西，sheet 会把窗口其余部分锁住，
//     用户没法一边翻网格一边看属性；
//   · 面板本身就是这些信息的归属地，换页不换容器 = 不多一层 z 序，
//     也不用再为浮层付一份材质 / 双层阴影（规格 §9 的性能红线）；
//   · 返回是一个 ‹ 按钮 + 切换截图自动回到摘要页（见 ShotDetailPane）。
//
// 页面自己查数据（修订链 / 分类 / 场景标签 / 敏感区域）而不是从摘要页传参：
// 这些查询只在用户真的点进来时发生，摘要页因此少挂四个 @State。

/// 修订的展示用快照。避免在 body 里反复解 layersJSON。
private struct RevisionSummary: Identifiable {
    let id: Int64
    let version: Int
    let note: String
    let layerCount: Int
    let createdAt: Date
}

struct ShotInfoPage: View {

    let shot: Shot
    let onBack: () -> Void

    @ObservedObject private var store: ShotStore

    init(shot: Shot, onBack: @escaping () -> Void, store: ShotStore = .shared) {
        self.shot = shot
        self.onBack = onBack
        _store = ObservedObject(wrappedValue: store)
    }

    @State private var revisions: [RevisionSummary] = []
    @State private var category: String?
    @State private var visionLabels: String?
    @State private var sensitiveRegions: [SensitiveRegion] = []
    @State private var recordingPath: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: DS.s3) {
                    sourceCard
                    imageCard
                    recognitionCard
                    sensitiveCard
                    recordingCard
                    historyCard
                }
                .padding(.horizontal, DS.s4)
                .padding(.bottom, DS.s4)
            }
        }
        .task(id: shot.id) { load() }
        // 属性由后台分析异步补上（OCR / 分类 / 指纹 / 敏感区域），修订链由编辑器
        // 保存时追加 —— 两者落库都会发布 store 变更，这里跟着重查。
        // 全是单行 LIMIT 1 / 短列表查询，代价可忽略。
        .onReceive(store.objectWillChange) { _ in load() }
    }

    /// 返回行。标题右侧留出 36pt —— 面板右上角那个 ✕ 是外层
    /// `GalleryInspectorPanel` 画的，标题不能钻到它下面。
    private var header: some View {
        HStack(spacing: DS.s2) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: DS.font12, weight: .semibold))
            }
            .buttonStyle(.inspectorCircle)
            .help("返回详情")
            .accessibilityLabel("返回详情")

            Text("全部信息")
                .font(.system(size: DS.font15, weight: .semibold))

            Spacer(minLength: 0)
        }
        .padding(.leading, DS.s3)
        .padding(.trailing, InspectorMetrics.closeButtonLane - DS.s1)
        .padding(.top, DS.s2)
        .padding(.bottom, DS.s3)
    }

    // MARK: - 分组卡片

    /// 分组卡片：`.quaternary` 底 + 卡片圆角 + caption.semibold 组题。
    ///
    /// 底色**只能是这类半透明填充，不能换成 Material**：外层面板是不透明的
    /// 纯色底（`floatingPanel`），卡片再上材质就是在实色上做一次白付的模糊。
    /// 同心圆角：外 10、内缩 s3(12) → 内层 = −2 → 归零，所以卡内元素一律直角
    ///（见 RevisionRow）。这正是公式该给出的答案，不是偷懒。
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
            DS.insetSurface,
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
                CopyValueRow(label: "网址", value: url)
            }
            row("显示器", shot.displayName)
            row("时间", shot.capturedAt.formatted(date: .complete, time: .standard))
        }
    }

    /// 图像与文件：像素、倍率、选区、原图路径、内容哈希。
    /// 路径与 sha256 只在这里出现 —— 摘要页放不下，但排查问题时必须能拿到。
    private var imageCard: some View {
        card("图像与文件") {
            row("尺寸", "\(shot.pixelWidth) × \(shot.pixelHeight) px")
            row("倍率", "@\(String(format: "%.0f", shot.scale))x")
            row("选区", String(
                format: "x %.0f  y %.0f  %.0f × %.0f",
                shot.regionX, shot.regionY, shot.regionW, shot.regionH
            ))
            CopyValueRow(label: "sha256", value: shot.sha256)
            CopyValueRow(label: "原图", value: store.originalURL(for: shot).path)
            Button {
                SystemNavigator.revealInFinder(store.originalURL(for: shot))
            } label: {
                Label("在访达中显示", systemImage: "folder")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(DS.accent)
        }
    }

    /// 机器补出来的信息（分类、Vision 场景标签、OCR 全文），和采集自系统的「来源」分开。
    @ViewBuilder
    private var recognitionCard: some View {
        let ocr = shot.ocrText ?? ""
        if category != nil || visionLabels != nil || !ocr.isEmpty {
            card("识别") {
                row("分类", category)
                row("场景标签", visionLabels)
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

    /// 敏感命中的明细。**摘要页只给「几处什么」的汇总**，
    /// 具体命中内容（邮箱、密钥片段）只在用户主动下钻时才铺开。
    @ViewBuilder
    private var sensitiveCard: some View {
        if !sensitiveRegions.isEmpty {
            card("敏感内容（\(sensitiveRegions.count)）") {
                ForEach(Array(sensitiveRegions.enumerated()), id: \.offset) { _, region in
                    HStack(alignment: .firstTextBaseline, spacing: DS.s2) {
                        Text(region.kind)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 64, alignment: .leading)
                        Text(region.preview)
                            .font(.caption)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var recordingCard: some View {
        if let path = recordingPath {
            let recording = RecordingAsset(path: path)
            card("录屏") {
                CopyValueRow(label: "文件", value: path)
                Button {
                    RecordingAssetActions.play(recording)
                } label: {
                    Label(
                        recording.availableURL == nil ? "录像文件缺失" : "打开录像",
                        systemImage: "play.rectangle"
                    )
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(DS.accent)
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

    // MARK: - 取数

    private func load() {
        revisions = store.revisions(for: shot).enumerated().map { index, rev in
            RevisionSummary(
                id: rev.id ?? Int64(index),
                version: index + 1,
                note: rev.note ?? "编辑",
                layerCount: rev.layers.count,
                createdAt: rev.createdAt
            )
        }
        guard let id = shot.id else {
            category = nil
            visionLabels = nil
            sensitiveRegions = []
            recordingPath = nil
            return
        }
        category = store.attributeText(shotID: id, key: AttributeKey.category)
        visionLabels = store.attributeText(shotID: id, key: AttributeKey.visionLabels)
        sensitiveRegions = store.attributePayload(shotID: id, key: AttributeKey.sensitiveRegions)
            .flatMap { try? JSONDecoder().decode([SensitiveRegion].self, from: $0) } ?? []
        recordingPath = store.recordingPath(for: shot)
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
            .padding(.leading, DS.s1 - 1)

            Circle()
                .fill(isLatest ? DS.accent : DS.dotInactive)
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
            .fill(isHovering ? DS.hoverFill : .clear)
        )
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        // 悬停提亮是微交互，走 micro（0.22 是「立刻发生」的感知阈）。
        .animation(DS.Motion.micro(reduced: reduceMotion), value: isHovering)
    }

    private var connector: some View {
        Rectangle()
            .fill(DS.connectorFill)
            .frame(width: 2)
            .frame(maxHeight: .infinity)
    }
}
