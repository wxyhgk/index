import SwiftUI
import AppKit

// ============================================================
// MARK: - 剪贴板历史视图：模式选择器 + 底栏 + 空状态
//
// 只读 internal 属性（viewModel/commands/store），
// 不触碰主文件的 private @State。
// ============================================================

extension ClipboardHistoryView {

    var workspaceModePicker: some View {
        HStack(spacing: 0) {
            ForEach(ClipboardWorkspaceMode.allCases) { mode in
                Button {
                    withAnimation(DS.Motion.standard) {
                        viewModel.workspaceMode = mode
                    }
                } label: {
                    Image(systemName: mode.systemImage)
                        .font(.system(size: DS.font12, weight: .medium))
                        .frame(width: 28, height: 22)
                        .foregroundStyle(viewModel.workspaceMode == mode ? DS.accent : .secondary)
                        .background(
                            viewModel.workspaceMode == mode ? DS.accent.opacity(0.14) : .clear,
                            in: RoundedRectangle(cornerRadius: DS.radiusSmall)
                        )
                }
                .buttonStyle(.plain)
                .disabled(viewModel.editingCapsuleID != nil && mode != .history)
                .help(mode.title)
                .accessibilityLabel(mode.title)
            }
        }
        .padding(2)
        .background(DS.iconPlaceholderFill, in: RoundedRectangle(cornerRadius: DS.radiusSmall))
    }

    var bottomBar: some View {
        ZStack {
            if viewModel.focusedGroup == nil {
                bottomCenteredSearch
            }

            HStack(spacing: DS.s3) {
                if viewModel.workspaceMode == .history && viewModel.focusedGroup == nil {
                    ClipboardFilterBar(
                        viewModel: viewModel,
                        showsFilters: true,
                        showsSearch: false,
                        usesIconFilters: true
                    )
                }

                Spacer()

                if viewModel.focusedGroup == nil {
                    bottomTrailingActions
                }
            }
        }
        .padding(.horizontal, DS.s4)
        .padding(.vertical, DS.s2)
        .background(.bar)
    }

    @ViewBuilder
    var bottomCenteredSearch: some View {
        if viewModel.workspaceMode != .capsules {
            ClipboardFilterBar(
                viewModel: viewModel,
                searchWidth: 280,
                showsFilters: false,
                showsSearch: true
            )
        } else {
            HStack(spacing: DS.s1) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: DS.font12))
                    .foregroundStyle(.tertiary)
                TextField("搜索胶囊、内容或来源", text: $viewModel.capsuleQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: DS.font13))
                    .frame(width: 280)
            }
            .padding(.horizontal, DS.s2)
            .padding(.vertical, DS.s1)
            .background(DS.iconPlaceholderFill, in: RoundedRectangle(cornerRadius: DS.radiusSmall))
        }
    }

    @ViewBuilder
    var bottomTrailingActions: some View {
        if let progress = viewModel.activeCapsulePaste {
            Button {
                viewModel.continueCapsulePaste()
            } label: {
                HStack(spacing: DS.s1) {
                    Image(systemName: "arrow.turn.down.left")
                    Text("\(progress.nextIndex + 1)/\(progress.items.count)")
                        .font(.system(size: DS.font10, weight: .semibold))
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .help(progress.progressLabel)
            .accessibilityLabel(progress.progressLabel)

            Button {
                viewModel.cancelCapsulePaste()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .help("结束逐项粘贴")
            .accessibilityLabel("结束逐项粘贴")
        } else if let editingName = viewModel.editingCapsuleName {
            Label(editingName, systemImage: "arrow.up.arrow.down")
                .font(.system(size: DS.font11, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: 140)

            Button {
                viewModel.cancelCapsuleEditing()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("取消编辑顺序")
            .accessibilityLabel("取消编辑顺序")

            Button {
                viewModel.saveCapsuleEditing()
            } label: {
                Image(systemName: "checkmark")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(viewModel.selectedCount == 0)
            .help("保存顺序")
            .accessibilityLabel("保存顺序")
        } else if viewModel.selectedCount > 0 {
            Label("\(viewModel.selectedCount)", systemImage: "checkmark.circle.fill")
                .font(.system(size: DS.font11, weight: .medium))
                .foregroundStyle(.secondary)
                .help("已选 \(viewModel.selectedCount) 项")

            Button {
                viewModel.createCapsuleFromQueue()
            } label: {
                Image(systemName: "shippingbox.and.arrow.backward")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("存为胶囊")
            .accessibilityLabel("存为胶囊")

            Button {
                viewModel.pasteSelected()
            } label: {
                Image(systemName: ClipboardHistoryCoordinator.shared.supportsDirectPaste
                    ? "arrow.turn.down.left"
                    : "doc.on.doc")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .help(ClipboardHistoryCoordinator.shared.supportsDirectPaste ? "粘贴" : "复制并返回")
            .accessibilityLabel(ClipboardHistoryCoordinator.shared.supportsDirectPaste ? "粘贴" : "复制并返回")
        }
    }

    var currentCountLabel: String {
        switch viewModel.workspaceMode {
        case .history:
            // 无搜索时显示数据库总条数（COUNT(*)），搜索时显示已加载匹配数
            if viewModel.query.trimmingCharacters(in: .whitespaces).isEmpty {
                return "\(viewModel.totalCount) 项"
            }
            return "\(viewModel.filteredItems.count) 项"
        case .sessions: return "\(viewModel.sessionGroups.count) 个项目"
        case .threads: return "\(viewModel.threads.count) 条线程"
        case .capsules: return "\(viewModel.filteredCapsules.count) 个胶囊"
        }
    }

    func workspaceEmptyState(icon: String, title: String, detail: String) -> some View {
        VStack(spacing: DS.s2) {
            Image(systemName: icon)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.system(size: DS.font13, weight: .semibold))
            Text(detail)
                .font(.system(size: DS.font11))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    var emptyState: some View {
        VStack(spacing: DS.s2) {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: DS.font20))
                .foregroundStyle(.tertiary)
            Text(viewModel.query.isEmpty ? "暂无剪贴板历史" : "没有匹配的结果")
                .font(.system(size: DS.font12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
