import SwiftUI

// MARK: - 搜索预览面板（右侧）
//
// 三层：内容区 → 元信息行 → 操作行。
// 视觉语言与主 App 统一：medium 字重、纯色底、DS.Motion 动效。

struct SearchPreviewPanel: View {
    @ObservedObject var viewModel: SearchPanelViewModel
    @State private var justCopied = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                        .font(.system(size: DS.font10, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .padding(DS.s2)
                }
        } else if let text = viewModel.previewText {
            ScrollView {
                Text(text)
                    .font(.system(size: DS.font12, weight: .regular, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(DS.s3)
            }
            .background(DS.insetSurface)
        } else {
            VStack(spacing: DS.s2) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(
                        size: SearchPanelMetrics.previewPlaceholderIconSize,
                        weight: .medium
                    ))
                    .foregroundStyle(.quaternary)
                Text("预览")
                    .font(.system(size: DS.font11, weight: .regular))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(DS.insetSurface)
        }
    }

    // MARK: 元信息行

    @ViewBuilder
    private var metaLine: some View {
        let entry = viewModel.selectedEntry
        if let entry {
            HStack(spacing: DS.s2) {
                metaChip(for: entry)
                Spacer()
                if let app = sourceApp(for: entry) {
                    HStack(spacing: SearchPanelMetrics.metadataSpacing) {
                        Image(systemName: "app.dashed")
                            .font(.system(size: DS.font9, weight: .medium))
                        Text(app)
                            .font(.system(size: DS.font10, weight: .regular))
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
            HStack(spacing: SearchPanelMetrics.metadataSpacing) {
                Image(systemName: metaIcon(for: entry))
                    .font(.system(size: DS.font9, weight: .medium))
                Text(meta)
                    .font(.system(size: DS.font10, weight: .regular))
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
                    try? await Task.sleep(for: DS.copyFeedbackDelay)
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

                actionButton(icon: "trash", help: "删除", tint: SearchPanelMetrics.destructiveTint) {
                    viewModel.deleteSelected()
                }
            }

            Spacer()

            if let entry = viewModel.selectedEntry {
                HStack(spacing: SearchPanelMetrics.metadataSpacing) {
                    Image(systemName: "clock")
                        .font(.system(size: DS.font9, weight: .medium))
                    Text(entry.timestamp, format: .dateTime.hour().minute())
                        .font(.system(size: DS.font10, weight: .regular))
                        .monospacedDigit()
                }
                .foregroundStyle(.quaternary)
            }
        }
        .padding(.horizontal, DS.s3)
        .padding(.vertical, DS.s2)
        .background(DS.panelFill(.overlay))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(DS.hairlineFill(scheme))
                .frame(height: SearchPanelMetrics.hairlineWidth)
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

// MARK: - 操作按钮（hover 出背景，与主 App ShellIconButtonStyle 同语言）

private struct ActionButton: View {
    let icon: String
    let tint: Color?
    let help: String
    let action: () -> Void

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: DS.font13, weight: .medium))
                .foregroundStyle(tint ?? .secondary)
                .frame(
                    width: SearchPanelMetrics.actionButtonSide,
                    height: SearchPanelMetrics.actionButtonSide
                )
                .background {
                    if hovering {
                        RoundedRectangle(cornerRadius: DS.radiusSmall, style: .continuous)
                            .fill(DS.shellHoverFill(scheme))
                    }
                }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .animation(DS.Motion.micro(reduced: reduceMotion), value: hovering)
    }
}
