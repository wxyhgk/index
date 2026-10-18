import SwiftUI

// ============================================================
// MARK: - 类型过滤 + 搜索栏（浮动面板和主窗口 tab 共用）
// ============================================================

struct ClipboardFilterBar: View {
    @ObservedObject var viewModel: ClipboardHistoryViewModel
    var searchWidth: CGFloat = 140
    var showsFilters = true
    var showsSearch = true
    var usesIconFilters = false

    @ViewBuilder
    var body: some View {
        if showsFilters {
            HStack(spacing: DS.s1) {
                filterTab("全部", systemImage: "square.grid.2x2", kind: nil)
                filterTab("文本", systemImage: "text.alignleft", kind: .text)
                filterTab("图片", systemImage: "photo", kind: .image)
                filterTab("文件", systemImage: "doc", kind: .file)
                filterTab("链接", systemImage: "link", kind: .text, tag: "url")
                filterTab("代码", systemImage: "chevron.left.forwardslash.chevron.right", kind: .text, tag: "code")
            }
        }
        if showsSearch {
            HStack(spacing: DS.s1) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: DS.font12))
                    .foregroundStyle(.tertiary)
                TextField("搜索", text: $viewModel.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: DS.font13))
                    .frame(width: searchWidth)
                    .onChange(of: viewModel.query) { _, _ in
                        viewModel.searchChanged()
                    }
            }
            .padding(.horizontal, DS.s2)
            .padding(.vertical, DS.s1)
            .background(DS.iconPlaceholderFill, in: RoundedRectangle(cornerRadius: DS.radiusSmall))
        }
    }

    private func filterTab(
        _ title: String,
        systemImage: String,
        kind: ClipboardHistoryKind?,
        tag: String? = nil
    ) -> some View {
        let isSelected = viewModel.typeFilter == kind && viewModel.tagFilter == tag
        return Button {
            viewModel.setTypeFilter(kind, tag: tag)
        } label: {
            Group {
                if usesIconFilters {
                    Image(systemName: systemImage)
                        .font(.system(size: DS.font12, weight: .medium))
                        .frame(width: 26, height: 22)
                } else {
                    Text(title)
                        .font(.system(
                            size: DS.font12,
                            weight: isSelected ? .semibold : .regular
                        ))
                        .padding(.horizontal, DS.s2)
                        .padding(.vertical, DS.s1)
                }
            }
            .background(
                isSelected
                    ? DS.accent.opacity(0.15)
                    : Color.clear,
                in: RoundedRectangle(cornerRadius: DS.radiusSmall)
            )
            .foregroundStyle(isSelected ? DS.accent : .secondary)
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
    }
}
