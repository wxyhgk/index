import SwiftUI
import AppKit

@MainActor
final class GallerySelection: ObservableObject {
    static let shared = GallerySelection()
    @Published var selectedID: Int64?
    @Published var editing: Shot?
}

struct GalleryView: View {

    @ObservedObject private var store = ShotStore.shared
    @ObservedObject private var selection = GallerySelection.shared

    private let columns = [GridItem(.adaptive(minimum: 190, maximum: 260), spacing: 14)]

    private var selectedShot: Shot? {
        store.shots.first { $0.id == selection.selectedID }
    }

    var body: some View {
        HSplitView {
            libraryPane
                .frame(minWidth: 420, idealWidth: 660)

            if let shot = selectedShot {
                ShotDetailPane(shot: shot)
                    .frame(minWidth: 300, idealWidth: 340, maxWidth: 460)
            } else {
                emptyDetail
                    .frame(minWidth: 300, idealWidth: 340, maxWidth: 460)
            }
        }
        .frame(minWidth: 860, minHeight: 560)
        .sheet(item: $selection.editing) { shot in
            EditorView(shot: shot)
        }
    }

    // MARK: 左侧

    private var libraryPane: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()

            if store.shots.isEmpty {
                emptyLibrary
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(store.shots) { shot in
                            ShotThumbnail(shot: shot, isSelected: shot.id == selection.selectedID)
                                // 单击必须独立识别。如果写成串联的 onTapGesture(count:2) + onTapGesture，
                                // SwiftUI 会等满系统双击间隔（0.5s）确认不是双击才派发单击 —— 表现就是点一下要等半秒。
                                .onTapGesture { selection.selectedID = shot.id }
                                .simultaneousGesture(
                                    TapGesture(count: 2).onEnded { selection.editing = shot }
                                )
                                .contextMenu {
                                    Button("编辑标注") { selection.editing = shot }
                                    Button("钉在桌面") { pin(shot) }
                                    Button("复制图片") { copy(shot) }
                                    Divider()
                                    Button("在访达中显示") { reveal(shot) }
                                    Button("删除", role: .destructive) { store.delete(shot) }
                                }
                        }
                    }
                    .padding(14)
                }
            }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("搜索 App、窗口标题、网址或截图中的文字…", text: $store.searchText)
                .textFieldStyle(.plain)
                .onSubmit { store.reload() }
                .onChange(of: store.searchText) { _, _ in store.reload() }
            if !store.searchText.isEmpty {
                Button {
                    store.searchText = ""
                    store.reload()
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var emptyLibrary: some View {
        VStack(spacing: 10) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text(store.searchText.isEmpty ? "还没有截图" : "没有匹配的结果")
                .foregroundStyle(.secondary)
            if store.searchText.isEmpty {
                Text("按 ⌃⌘A 开始截图")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyDetail: some View {
        Text("选择一张截图")
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.background.secondary)
    }

    // MARK: 动作

    private func pin(_ shot: Shot) {
        guard let base = store.originalImage(for: shot) else { return }
        PinWindowController.pin(
            base: base,
            layers: store.latestRevision(for: shot)?.imageLayers ?? Layers(),
            shot: shot,
            at: .zero
        )
    }

    private func copy(_ shot: Shot) {
        guard let base = store.originalImage(for: shot) else { return }
        let layers = store.latestRevision(for: shot)?.imageLayers ?? Layers()
        ImageCodec.copyToPasteboard(LayerRenderer.render(base: base, layers: layers))
    }

    private func reveal(_ shot: Shot) {
        NSWorkspace.shared.activateFileViewerSelecting([store.originalURL(for: shot)])
    }
}

// MARK: - 缩略图

private struct ShotThumbnail: View {
    let shot: Shot
    let isSelected: Bool

    // 刻意不用 @ObservedObject 订阅 store —— 只需要一个文件路径，
    // 订阅了会导致任何 store 变化都重建全部缩略图。
    private var thumbnailURL: URL { ShotStore.shared.thumbnailURL(for: shot) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.background.secondary)
                CachedImage(url: thumbnailURL, key: shot.sha256)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .frame(height: 130)
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.1),
                                  lineWidth: isSelected ? 2.5 : 1)
            }

            Text(shot.appName ?? "未知 App")
                .font(.caption).bold()
                .lineLimit(1)
            Text(shot.capturedAt, format: .dateTime.month().day().hour().minute())
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - 右侧详情

/// 修订的展示用快照。避免在 body 里反复解 layersJSON。
private struct RevisionSummary: Identifiable {
    let id: Int64
    let version: Int
    let note: String
    let layerCount: Int
    let createdAt: Date
}

private struct ShotDetailPane: View {
    let shot: Shot

    private let store = ShotStore.shared
    @ObservedObject private var selection = GallerySelection.shared

    /// 修订历史只在切换截图 / 关闭编辑器时查一次数据库，不再挂在 body 上。
    @State private var revisions: [RevisionSummary] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                preview
                actions
                Divider()
                metadataSection
                Divider()
                historySection
            }
            .padding(16)
        }
        .background(.background.secondary)
        .task(id: shot.id) { loadRevisions() }
        .onChange(of: selection.editing) { _, newValue in
            if newValue == nil { loadRevisions() }
        }
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
        CachedImage(url: store.thumbnailURL(for: shot), key: shot.sha256)
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button {
                selection.editing = shot
            } label: {
                Label("编辑", systemImage: "pencil.tip.crop.circle")
            }
            Button {
                guard let base = store.originalImage(for: shot) else { return }
                PinWindowController.pin(
                    base: base,
                    layers: store.latestRevision(for: shot)?.imageLayers ?? Layers(),
                    shot: shot,
                    at: .zero
                )
            } label: {
                Label("钉图", systemImage: "pin")
            }
            Button {
                export()
            } label: {
                Label("导出", systemImage: "square.and.arrow.up")
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private var metadataSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("来源").font(.headline)
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

            if let ocr = shot.ocrText, !ocr.isEmpty {
                DisclosureGroup("识别文字（\(ocr.count) 字）") {
                    Text(ocr)
                        .font(.caption)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.caption)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("修订历史（\(revisions.count)）").font(.headline)
            Text("每次编辑都追加一条记录，原图从不被修改。")
                .font(.caption2)
                .foregroundStyle(.secondary)

            ForEach(revisions) { rev in
                let isLatest = rev.id == revisions.last?.id
                HStack(spacing: 8) {
                    Image(systemName: isLatest ? "circle.fill" : "circle")
                        .font(.system(size: 7))
                        .foregroundStyle(isLatest ? Color.accentColor : .secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("v\(rev.version) · \(rev.note)")
                            .font(.caption)
                        Text("\(rev.layerCount) 个图层 · \(rev.createdAt.formatted(date: .omitted, time: .shortened))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            HStack(alignment: .top, spacing: 8) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 74, alignment: .leading)
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
