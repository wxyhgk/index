import SwiftUI
import AppKit

// ============================================================
// MARK: - 剪贴板历史视图：线程卡片 + 粘贴队列 + 改名入口
//
// 只读 internal 属性和外部类型，不触碰主文件的 private @State。
// ============================================================

extension ClipboardHistoryView {

    func threadContextLabel(_ thread: ClipboardThread) -> String {
        let source = thread.sourceApps.prefix(2).joined(separator: " · ")
        let duration = max(0, Int(thread.endedAt.timeIntervalSince(thread.startedAt)))
        let durationText: String
        if duration < 60 {
            durationText = "\(duration) 秒"
        } else {
            durationText = "\(max(1, duration / 60)) 分钟"
        }
        return source.isEmpty ? "跨度 \(durationText)" : "\(source) · \(durationText)"
    }

    func threadCard(_ thread: ClipboardThread) -> some View {
        VStack(alignment: .leading, spacing: DS.s2) {
            HStack(spacing: DS.s2) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .foregroundStyle(DS.accent)
                Text(thread.title)
                    .font(.system(size: DS.font13, weight: .semibold))
                    .lineLimit(1)
                Spacer()
                Text("\(thread.items.count) 项")
                    .font(.system(size: DS.font11, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: DS.s1) {
                ForEach(Array(thread.items.prefix(3).enumerated()), id: \.offset) { index, item in
                    HStack(spacing: DS.s2) {
                        Text("\(index + 1)")
                            .font(.system(size: DS.font10, weight: .semibold))
                            .foregroundStyle(DS.accent)
                            .frame(width: 14)
                        Text(item.displayName)
                            .font(.system(size: DS.font11))
                            .lineLimit(1)
                    }
                }
                if thread.items.count > 3 {
                    Text("还有 \(thread.items.count - 3) 项")
                        .font(.system(size: DS.font11))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)

            HStack(spacing: DS.s2) {
                Text(threadContextLabel(thread))
                    .font(.system(size: DS.font10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Spacer()
                Text(ClipboardCardPresentation.relativeTime(for: thread.endedAt))
                    .font(.system(size: DS.font10))
                    .foregroundStyle(.tertiary)
            }

            HStack(spacing: DS.s2) {
                Button {
                    viewModel.loadPasteQueue(Array(thread.items.reversed()))
                } label: {
                    Image(systemName: "list.number")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("检查粘贴顺序")
                .accessibilityLabel("检查粘贴顺序")

                Button {
                    viewModel.createCapsule(from: thread)
                } label: {
                    Image(systemName: "shippingbox.and.arrow.backward")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .help("存为胶囊")
                .accessibilityLabel("存为胶囊")
            }
        }
        .padding(DS.s3)
        .frame(width: 270, height: ClipboardCardMetrics.popupHeight, alignment: .topLeading)
        .background(DS.panelFill(.resting), in: RoundedRectangle(
            cornerRadius: DS.radiusCard,
            style: .continuous
        ))
        .overlay {
            RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 1)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(DS.Motion.standard) {
                viewModel.focusedGroup = FocusedGroup(label: thread.title, items: thread.items)
                viewModel.workspaceMode = .history
            }
        }
    }

    var pasteQueueRail: some View {
        VStack(spacing: DS.s2) {
            HStack {
                Image(systemName: "list.number")
                    .font(.system(size: DS.font12, weight: .semibold))
                    .help("粘贴队列")
                    .accessibilityLabel("粘贴队列")
                Spacer()
                Text("\(viewModel.selectedCount)")
                    .font(.system(size: DS.font11, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            if viewModel.pasteQueueItems.isEmpty {
                Text("在右侧点击卡片加入队列")
                    .font(.system(size: DS.font11))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: DS.s1) {
                        ForEach(Array(viewModel.pasteQueueItems.enumerated()), id: \.offset) { index, item in
                            pasteQueueRow(item, ordinal: index + 1)
                        }
                    }
                }
            }

            HStack(spacing: DS.s2) {
                Button {
                    viewModel.clearPasteQueue()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(viewModel.pasteQueueItems.isEmpty)
                .help("清空粘贴队列")
                .accessibilityLabel("清空粘贴队列")

                Button {
                    viewModel.pasteSelected()
                } label: {
                    Image(systemName: ClipboardHistoryCoordinator.shared.supportsDirectPaste
                        ? "arrow.turn.down.left"
                        : "doc.on.doc")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(viewModel.pasteQueueItems.isEmpty)
                .help(ClipboardHistoryCoordinator.shared.supportsDirectPaste ? "粘贴" : "复制并返回")
                .accessibilityLabel(ClipboardHistoryCoordinator.shared.supportsDirectPaste ? "粘贴" : "复制并返回")
            }
        }
        .padding(DS.s3)
        .background(DS.panelFill(.resting))
    }

    func pasteQueueRow(_ item: ClipboardHistoryItem, ordinal: Int) -> some View {
        HStack(spacing: DS.s2) {
            Text("\(ordinal)")
                .font(.system(size: DS.font11, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(DS.accent, in: Circle())

            Image(systemName: queueIcon(for: item.kind))
                .font(.system(size: DS.font12))
                .foregroundStyle(.secondary)
                .frame(width: 16)

            Text(item.displayName)
                .font(.system(size: DS.font11))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 0) {
                Button {
                    viewModel.movePasteQueueItem(item, by: -1)
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 8, weight: .bold))
                }
                .buttonStyle(.plain)
                .disabled(ordinal == 1)
                .help("向前移动")

                Button {
                    viewModel.movePasteQueueItem(item, by: 1)
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                }
                .buttonStyle(.plain)
                .disabled(ordinal == viewModel.selectedCount)
                .help("向后移动")
            }

            Button {
                viewModel.removeFromPasteQueue(item)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: DS.font11, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("从粘贴队列移除")
        }
        .padding(.horizontal, DS.s2)
        .padding(.vertical, DS.s1)
        .background(DS.panelFill(.overlay), in: RoundedRectangle(
            cornerRadius: DS.radiusSmall,
            style: .continuous
        ))
    }

    func sessionCard(_ group: ClipboardSessionGroup) -> some View {
        VStack(alignment: .leading, spacing: DS.s2) {
            // 点击卡片进入聚焦模式查看全部条目
            HStack(spacing: DS.s2) {
                Image(systemName: "folder")
                    .foregroundStyle(DS.accent)
                Text(group.label)
                    .font(.system(size: DS.font13, weight: .semibold))
                    .lineLimit(1)
                Spacer()
                Text("\(group.items.count) 项")
                    .font(.system(size: DS.font11, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: DS.s1) {
                ForEach(Array(group.items.prefix(3).enumerated()), id: \.offset) { index, item in
                    HStack(spacing: DS.s2) {
                        Text("\(index + 1)")
                            .font(.system(size: DS.font10, weight: .semibold))
                            .foregroundStyle(DS.accent)
                            .frame(width: 14)
                        Text(item.displayName)
                            .font(.system(size: DS.font11))
                            .lineLimit(1)
                    }
                }
                if group.items.count > 3 {
                    Text("还有 \(group.items.count - 3) 项")
                        .font(.system(size: DS.font11))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)

            HStack(spacing: DS.s2) {
                Text(group.durationText)
                    .font(.system(size: DS.font10))
                    .foregroundStyle(.tertiary)
                Spacer()
                Text(ClipboardCardPresentation.relativeTime(for: group.latestAt))
                    .font(.system(size: DS.font10))
                    .foregroundStyle(.tertiary)
            }

            HStack(spacing: DS.s2) {
                Button {
                    viewModel.loadPasteQueue(Array(group.items.reversed()))
                } label: {
                    Image(systemName: "list.number")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("加载到粘贴队列")
                .accessibilityLabel("加载到粘贴队列")
            }
        }
        .padding(DS.s3)
        .frame(width: 270, height: ClipboardCardMetrics.popupHeight, alignment: .topLeading)
        .background(DS.panelFill(.resting), in: RoundedRectangle(
            cornerRadius: DS.radiusCard,
            style: .continuous
        ))
        .overlay {
            RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 1)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(DS.Motion.standard) {
                viewModel.focusedGroup = FocusedGroup(label: group.label, items: group.items)
                viewModel.workspaceMode = .history
            }
        }
    }

    func queueIcon(for kind: ClipboardHistoryKind) -> String {
        switch kind {
        case .text: return "text.alignleft"
        case .image: return "photo"
        case .file: return "doc"
        }
    }

    func beginRenamingSelectedItem() {
        let visible = viewModel.filteredItems
        guard visible.indices.contains(viewModel.selectedIndex) else { return }
        beginRenaming(visible[viewModel.selectedIndex])
    }
}
