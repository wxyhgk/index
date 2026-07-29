import SwiftUI

// MARK: - 相似截图
//
// 「查找相似」的结果 sheet 与它专用的结果卡片。
// 网格右键和详情栏「更多」菜单都从这里弹。

/// 「查找相似」结果。指纹距离在 ShotStore 里已算好并升序排好，这里只管展示。
struct SimilarShotsSheet: View {
    let shot: Shot

    @Environment(\.dismiss) private var dismiss
    /// nil = 还在比对；空数组 = 比对完但没有可比的候选。
    @State private var results: [Shot]?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("相似截图", systemImage: "sparkles.rectangle.stack")
                    .font(.headline)
                Spacer()
                Button("关闭") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(14)

            Divider()

            if let results {
                if results.isEmpty {
                    ContentUnavailableView(
                        "没有可比对的截图",
                        systemImage: "sparkles.rectangle.stack",
                        description: Text("其它截图还没完成特征分析，稍后再试")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 150, maximum: 210), spacing: 14)],
                            spacing: 16
                        ) {
                            ForEach(results) { result in
                                SimilarShotCard(shot: result)
                                    .onTapGesture {
                                        // 定位类场景：清空多选后单选目标。
                                        GallerySelection.shared.select(only: result.id)
                                        dismiss()
                                    }
                            }
                        }
                        .padding(16)
                    }
                }
            } else {
                ProgressView("正在比对特征指纹…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 640, height: 440)
        .task(id: shot.id) {
            results = await ShotStore.shared.similarShots(to: shot)
        }
    }
}

/// 相似结果卡片：缩略图 + App 名 + 时间。刻意比 ShotCard 简单 ——
/// 结果按相似度排序本身就是提示，不展示精确距离数值。
private struct SimilarShotCard: View {
    let shot: Shot

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.quaternary.opacity(0.5))
                CachedImage(url: ShotStore.shared.thumbnailURL(for: shot), key: shot.sha256)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .frame(height: 100)
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.primary.opacity(isHovering ? 0.3 : 0.08), lineWidth: 1)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(shot.appName ?? "未知 App")
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                Text(shot.capturedAt, format: .dateTime.month().day().hour().minute())
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 2)
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
    }
}
