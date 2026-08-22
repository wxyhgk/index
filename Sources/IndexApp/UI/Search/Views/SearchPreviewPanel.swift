import SwiftUI

// MARK: - 搜索预览面板（右侧，苹果黑白风）
//
// 三层：内容区 → 元信息行（图标引导）→ 操作行（图标按钮）。
// 所有图标 thin 字重，纯灰度。

struct SearchPreviewPanel: View {
    @ObservedObject var viewModel: SearchPanelViewModel
    @State private var justCopied = false

    var body: some View {
        VStack(spacing: 0) {
            contentArea
            metaLine
            actionBar
        }
    }

    // MARK: 内容区

    @ViewBuilder
    private var contentArea: some View {
        if let image = viewModel.previewImage {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(DS.s3)
                .background(DS.insetSurface)
                .contentShape(Rectangle())
                .onTapGesture {
                    SearchImagePreviewWindow.shared.show(
                        image: image,
                        originalURL: viewModel.originalURL(for: viewModel.selectedEntry)
                    )
                }
                .onDrag {
                    if let entry = viewModel.selectedEntry {
                        return viewModel.dragProvider(for: entry)
                    }
                    return NSItemProvider()
                }
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 10, weight: .thin))
                        .foregroundStyle(.tertiary)
                        .padding(DS.s2)
                }
        } else if let text = viewModel.previewText {
            ScrollView {
                Text(text)
                    .font(.system(size: 12, weight: .light, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(DS.s3)
            }
            .background(DS.insetSurface)
        } else {
            VStack(spacing: DS.s2) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 22, weight: .ultraLight))
                    .foregroundStyle(.quaternary)
                Text("预览")
                    .font(.system(size: 11, weight: .light))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(DS.insetSurface)
        }
    }

    // MARK: 元信息行（图标引导）

    @ViewBuilder
    private var metaLine: some View {
        let entry = viewModel.selectedEntry
        if let entry {
            HStack(spacing: DS.s2) {
                metaChip(for: entry)
                Spacer()
                if let app = sourceApp(for: entry) {
                    HStack(spacing: 3) {
                        Image(systemName: "app.dashed")
                            .font(.system(size: 9, weight: .thin))
                        Text(app)
                            .font(.system(size: 10, weight: .light))
                    }
                    .foregroundStyle(.quaternary)
                    .lineLimit(1)
                }
            }
            .padding(.horizontal, DS.s3)
            .padding(.vertical, DS.s1)
        }
    }

    @ViewBuilder
    private func metaChip(for entry: SearchEntry) -> some View {
        let meta = viewModel.metaLine(for: entry)
        if !meta.isEmpty {
            HStack(spacing: 3) {
                Image(systemName: metaIcon(for: entry))
                    .font(.system(size: 9, weight: .thin))
                Text(meta)
                    .font(.system(size: 10, weight: .light))
            }
            .foregroundStyle(.quaternary)
            .lineLimit(1)
        }
    }

    private func metaIcon(for entry: SearchEntry) -> String {
        switch entry.kind {
        case .screenshot, .recording: return "ruler"
        case .clipboardImage: return "ruler"
        case .clipboardText: return "character.cursor.text"
        case .clipboardFile: return "doc"
        }
    }

    private func sourceApp(for entry: SearchEntry) -> String? {
        guard !entry.subtitle.isEmpty else { return nil }
        return entry.subtitle
    }

    // MARK: 操作行

    private var actionBar: some View {
        HStack(spacing: DS.s2) {
            actionButton(
                icon: justCopied ? "checkmark" : "doc.on.doc",
                help: "复制",
                tint: justCopied ? .green : nil
            ) {
                viewModel.copySelected()
                justCopied = true
                Task {
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    justCopied = false
                }
            }

            actionButton(icon: "arrow.down.to.line", help: "复制并粘贴") {
                viewModel.copyAndPasteSelected()
            }

            if viewModel.isClipboardEntry {
                actionButton(icon: "tray.and.arrow.down", help: "保存到图库") {
                    viewModel.saveSelectedToLibrary()
                }

                actionButton(icon: "trash", help: "删除", tint: .red.opacity(0.6)) {
                    viewModel.deleteSelected()
                }
            }

            Spacer()

            if let entry = viewModel.selectedEntry {
                HStack(spacing: 3) {
                    Image(systemName: "clock")
                        .font(.system(size: 9, weight: .thin))
                    Text(entry.timestamp, format: .dateTime.hour().minute())
                        .font(.system(size: 10, weight: .light))
                        .monospacedDigit()
                }
                .foregroundStyle(.quaternary)
            }
        }
        .padding(.horizontal, DS.s3)
        .padding(.vertical, DS.s2)
        .background(.bar)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(.separator)
                .frame(height: 0.5)
        }
    }

    private func actionButton(
        icon: String,
        help: String,
        tint: Color? = nil,
        action: @escaping () -> Void
    ) -> some View {
        ActionButton(icon: icon, tint: tint, help: help, action: action)
    }
}

// MARK: - 极简操作按钮（hover 才出背景）

private struct ActionButton: View {
    let icon: String
    let tint: Color?
    let help: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .thin))
                .foregroundStyle(tint ?? .secondary)
                .frame(width: 24, height: 24)
                .background {
                    if hovering {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(.primary.opacity(0.06))
                    }
                }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}
