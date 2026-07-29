import SwiftUI

// MARK: - 多选详情栏
//
// 选中多张时占据 inspector 的那块面板：拼贴预览 + 批量动作按钮 + 导出结果提示。
// 动作本身在 GalleryBatch，这里只管呈现。

/// 选中 N>1 张时替换 ShotDetailPane 的批量面板：
/// 「已选 N 张」+ 2×2 缩略图拼贴 + 批量动作（收藏 / 导出 / 删除）。
///
/// 和 ShotDetailPane 一样：这栏站在 `.inspector` 自动给的材质上，
/// 面板本身和拼贴格子都**不加任何 Material**，格子底只用 `.quaternary`。
struct MultiSelectionPane: View {
    /// 展示顺序的选中截图，由 GalleryView 解析好传入。
    let shots: [Shot]

    // 订阅 store 是为了收藏态实时刷新（批量收藏后按钮文案要翻转）。
    @ObservedObject private var store = ShotStore.shared
    @ObservedObject private var selection = GallerySelection.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 最近一次批量导出的结果提示，几秒后自动消失。
    @State private var exportSummary: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.s3) {
                collage
                Text("已选 \(shots.count) 张")
                    .font(.title3.weight(.semibold))
                Text("批量动作作用于全部选中项。按 Esc 回到单选。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                actions
                if let exportSummary {
                    Label(exportSummary, systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.green)
                        .transition(.opacity)
                }
            }
            .padding(DS.s4)
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
                        .fill(.quaternary.opacity(0.5))
                    CachedImage(url: store.thumbnailURL(for: shot), key: shot.sha256)
                        .clipShape(RoundedRectangle(cornerRadius: DS.radiusSmall, style: .continuous))
                }
                .frame(height: 76)
                .overlay {
                    if shot.id == previews.last?.id, shots.count > 4 {
                        RoundedRectangle(cornerRadius: DS.radiusSmall, style: .continuous)
                            .fill(.black.opacity(0.45))
                        Text("+\(shots.count - 4)")
                            .font(.title3.weight(.bold))
                            .foregroundStyle(.white)
                    }
                }
            }
        }
    }

    private var actions: some View {
        VStack(spacing: DS.s2) {
            let allFavorited = GalleryBatch.allFavorited(shots)
            Button {
                GalleryBatch.toggleFavorites(shots)
            } label: {
                Label(
                    allFavorited ? "取消收藏 \(shots.count) 张" : "全部收藏",
                    systemImage: allFavorited ? "star.slash" : "star"
                )
                .frame(maxWidth: .infinity)
            }

            Button {
                runExport()
            } label: {
                Label("导出 \(shots.count) 张…", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .help("选一个目录，逐张按文件名模板导出成品（含标注），重名自动加序号")

            Button(role: .destructive) {
                selection.pendingDeleteIDs = shots.compactMap(\.id)
            } label: {
                Label("删除 \(shots.count) 张…", systemImage: "trash")
                    .frame(maxWidth: .infinity)
            }
        }
        .buttonStyle(.bordered)
    }

    private func runExport() {
        let targets = shots
        Task {
            let exported = await GalleryBatch.exportAll(targets)
            guard exported > 0 else { return }
            // 结果提示是一个小件的出没，走 micro（§6）：出得快才像「刚刚完成」。
            withAnimation(DS.Motion.micro(reduced: reduceMotion)) {
                exportSummary = exported < targets.count
                    ? "已导出 \(exported)/\(targets.count) 张"
                    : "已导出 \(exported) 张"
            }
            try? await Task.sleep(for: .seconds(4))
            withAnimation(DS.Motion.micro(reduced: reduceMotion)) { exportSummary = nil }
        }
    }
}
