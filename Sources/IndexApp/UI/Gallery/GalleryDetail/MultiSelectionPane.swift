import SwiftUI

// MARK: - 多选详情栏
//
// 选中多张时占据 inspector 的那块面板：拼贴预览 + 批量动作按钮 + 导出结果提示。
// 动作本身在 GalleryBatch，这里只管呈现。

/// 选中 N>1 张时替换 ShotDetailPane 的批量面板：
/// 「已选 N 张」+ 2×2 缩略图拼贴 + 批量动作（收藏 / 导出 / 删除）。
///
/// 设计稿没画多选态，但它不能因此变得风格割裂：视觉语言整套对齐单选面板 ——
/// 同一条关闭按钮空巷、同一档主按钮（accent 实心胶囊）与次级按钮（浅色胶囊）、
/// 同样的 `DS.s4` 内边距。功能一件没动。
///
/// 和 ShotDetailPane 一样：外层 `floatingPanel` 已经是不透明纯色底，
/// 面板本身和拼贴格子都**不加任何 Material**，格子底只用 `.quaternary`。
struct MultiSelectionPane: View {
    /// 展示顺序的选中截图，由 GalleryView 解析好传入。
    let shots: [Shot]

    // 订阅 store 是为了收藏态实时刷新（批量收藏后按钮文案要翻转）。
    @ObservedObject private var store: ShotStore
    @ObservedObject private var selection = GalleryWindowController.shared.selection
    @ObservedObject private var batchActivity = GalleryWindowController.shared.batchActivity

    init(shots: [Shot], store: ShotStore = .shared) {
        self.shots = shots
        _store = ObservedObject(wrappedValue: store)
    }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 最近一次批量导出的结果提示，几秒后自动消失。
    @State private var exportSummary: String?
    @State private var collectionSummaries: [ShotCollectionSummary] = []
    @State private var collectionMembershipCounts: [Int64: Int] = [:]
    @State private var collectionSnapshotGeneration = -1

    /// 导出结果提示的停留时长。
    private let exportSummaryDelay: Duration = .seconds(4)

    private var selectedIDs: [Int64] { selection.orderedSelectedIDs }
    private var selectedCount: Int { selectedIDs.count }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.s3) {
                collage
                Text("已选 \(selectedCount) 张")
                    .font(.title3.weight(.semibold))
                Text("批量动作作用于全部选中项。按 Esc 回到单选。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                actions
                if let state = batchActivity.state {
                    batchProgress(state)
                }
                if let exportSummary {
                    Label(exportSummary, systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.green)
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, DS.s4)
            // 和单选面板同一条巷子：面板右上角那个 ✕ 是外层
            // `GalleryInspectorPanel` 画的，拼贴不能钻到它下面。
            .padding(.top, InspectorMetrics.closeButtonLane)
            .padding(.bottom, DS.s4)
        }
        .task(id: selection.generation) { await refreshCollections() }
        .onReceive(store.libraryDidChangePublisher) {
            Task { await refreshCollections() }
        }
    }

    /// 2×2 拼贴：展示顺序前 4 张，超出的在最后一格盖 +N。
    private var collage: some View {
        let previews = Array(shots.prefix(4))
        return LazyVGrid(
            columns: [
                GridItem(.flexible(), spacing: DS.s2),
                GridItem(.flexible(), spacing: DS.s2)
            ],
            spacing: DS.s2
        ) {
            ForEach(previews) { shot in
                // 三层（底、图、+N 罩）都用同一个圆角：它们零内缩、完全重叠，
                // 同心公式下内层 = 外层 − 0 = 外层。全部补 .continuous。
                ZStack {
                    RoundedRectangle(cornerRadius: DS.radiusSmall, style: .continuous)
                        .fill(DS.insetSurface)
                    CachedImage(url: store.thumbnailURL(for: shot), key: shot.sha256)
                        .clipShape(RoundedRectangle(cornerRadius: DS.radiusSmall, style: .continuous))
                }
                .frame(height: 76)
                .overlay {
                    if shot.id == previews.last?.id, selectedCount > 4 {
                        RoundedRectangle(cornerRadius: DS.radiusSmall, style: .continuous)
                            .fill(DS.overlayDim)
                        Text("+\(selectedCount - 4)")
                            .font(.title3.weight(.bold))
                            .foregroundStyle(.white)
                    }
                }
            }
        }
    }

    /// 批量动作。三行整宽按钮：收藏是这块面板的主动作（accent 实心），
    /// 导出与删除退到次级浅色胶囊 —— 和单选面板「一个主按钮 + 一排次级位」
    /// 是同一条规矩（同屏只允许一个控件戴强调色，规格 §7.1）。
    private var actions: some View {
        VStack(spacing: DS.s2) {
            let ids = selectedIDs
            let allFavorited = GalleryBatch.allFavorited(ids: ids)
            Button {
                GalleryBatch.toggleFavorites(ids: ids)
            } label: {
                Label(
                    allFavorited ? "取消收藏 \(selectedCount) 张" : "全部收藏",
                    systemImage: allFavorited ? "star.slash" : "star"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.inspectorPillWide)
            .disabled(batchActivity.isBusy)

            Menu {
                if collectionSummaries.isEmpty {
                    // 与 ShotDetailPane / GalleryGrid+Card 同一文案（空专题集引导）。
                    Text("尚无专题集，请先到“收藏”页创建")
                } else {
                    ForEach(collectionSummaries) { collection in
                        let membershipKnown = collectionSnapshotGeneration == selection.generation
                        let isInAll = membershipKnown
                            && !ids.isEmpty
                            && collectionMembershipCounts[collection.id] == ids.count
                        Button {
                            setMembership(ids, collectionID: collection.id, remove: isInAll)
                        } label: {
                            Label(
                                collection.name,
                                systemImage: isInAll ? "checkmark" : "rectangle.stack.badge.plus"
                            )
                        }
                        .disabled(!membershipKnown)
                    }
                }
            } label: {
                Label("加入专题收藏集…", systemImage: "rectangle.stack.badge.plus")
                    .frame(maxWidth: .infinity)
            }
            .menuStyle(.button)
            .buttonStyle(.inspectorSoft)
            .disabled(collectionSummaries.isEmpty || batchActivity.isBusy)

            Button {
                runExport()
            } label: {
                Label("导出 \(selectedCount) 张…", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.inspectorSoft)
            .disabled(batchActivity.isBusy)
            .help("选一个目录，逐张按文件名模板导出成品（含标注），重名自动加序号")

            Button(role: .destructive) {
                selection.pendingDeleteIDs = ids
            } label: {
                Label("删除 \(selectedCount) 张…", systemImage: "trash")
                    .frame(maxWidth: .infinity)
            }
            // 破坏性动作用红字而不是红底：红底在这一列里比主动作还抢眼，
            // 会让「删除」读成推荐动作。
            .buttonStyle(.inspectorSoft(tint: .red))
            .disabled(batchActivity.isBusy)
        }
    }

    private func batchProgress(_ state: GalleryBatchActivity.State) -> some View {
        VStack(alignment: .leading, spacing: DS.s2) {
            HStack {
                Text(state.isCancelling ? "正在取消…" : state.kind.title)
                    .font(.caption.weight(.medium))
                Spacer()
                Text("\(state.processed)/\(state.total)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: state.progress)
            Button("取消") { batchActivity.cancel() }
                .buttonStyle(.inspectorSoft(tint: .red))
                .disabled(state.isCancelling)
        }
    }

    private func runExport() {
        let ids = selectedIDs
        Task {
            let exported = await GalleryBatch.exportAll(ids: ids)
            guard exported > 0 else { return }
            // 结果提示是一个小件的出没，走 micro（§6）：出得快才像「刚刚完成」。
            withAnimation(DS.Motion.micro(reduced: reduceMotion)) {
                exportSummary = exported < ids.count
                    ? "已导出 \(exported)/\(ids.count) 张"
                    : "已导出 \(exported) 张"
            }
            try? await Task.sleep(for: exportSummaryDelay)
            withAnimation(DS.Motion.micro(reduced: reduceMotion)) { exportSummary = nil }
        }
    }

    private func refreshCollections() async {
        let generation = selection.generation
        let ids = selectedIDs
        collectionSummaries = store.collectionSummaries()
        let counts = await store.collectionMembershipCountsInBackground(shotIDs: ids)
        guard generation == selection.generation else { return }
        collectionMembershipCounts = counts
        collectionSnapshotGeneration = generation
    }

    private func setMembership(_ ids: [Int64], collectionID: Int64, remove: Bool) {
        if remove {
            store.removeFromCollection(shotIDs: ids, collectionID: collectionID)
        } else {
            do {
                try store.addToCollection(shotIDs: ids, collectionID: collectionID)
            } catch {
                NSLog("[Index] 批量加入收藏集失败: \(error)")
            }
        }
        Task { await refreshCollections() }
    }
}
