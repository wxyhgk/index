import SwiftUI

// MARK: - Option+Space 全局搜索面板
//
// 视觉语言与主 App 统一：纯色面板、accent 选中、medium 字重、DS.Motion 动效。

struct SearchPanelView: View {
    @ObservedObject var viewModel: SearchPanelViewModel
    @FocusState private var searchFocused: Bool
    @State private var appeared = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            listSection
            SearchPreviewPanel(viewModel: viewModel)
                .frame(width: SearchPanelMetrics.previewWidth)
        }
        .frame(
            width: SearchPanelMetrics.panelSize.width,
            height: SearchPanelMetrics.panelSize.height
        )
        .background(DS.panelFill(.overlay))
        .clipShape(RoundedRectangle(cornerRadius: DS.radiusPanel, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DS.radiusPanel, style: .continuous)
                .strokeBorder(
                    DS.panelStroke(scheme, level: .overlay),
                    lineWidth: SearchPanelMetrics.hairlineWidth
                )
        }
        .scaleEffect(appeared ? 1 : SearchPanelMetrics.initialScale)
        .opacity(appeared ? 1 : 0)
        .onAppear {
            withAnimation(DS.Motion.standard(reduced: reduceMotion)) {
                appeared = true
            }
            DispatchQueue.main.async {
                searchFocused = true
            }
        }
    }

    // MARK: 左侧

    private var listSection: some View {
        VStack(spacing: 0) {
            searchBar
            resultList
        }
    }

    // MARK: 搜索框（胶囊容器，与主 App GallerySearchField 同语言）

    private var searchBar: some View {
        HStack(spacing: DS.s2) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: DS.font13, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("", text: $viewModel.query)
                .textFieldStyle(.plain)
                .font(.system(size: DS.font15, weight: .regular))
                .focused($searchFocused)
                .onChange(of: viewModel.query) { _, _ in
                    viewModel.searchChanged()
                }
            if !viewModel.query.isEmpty {
                Button {
                    viewModel.clear()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: DS.font12))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, DS.s3)
        .frame(height: 34)
        .background(
            Capsule().fill(DS.capsuleFill(scheme))
        )
        .overlay {
            Capsule().strokeBorder(
                searchFocused ? DS.accentStrokeFocus : DS.capsuleStroke(scheme),
                lineWidth: searchFocused ? 1.5 : 1
            )
        }
        .padding(.horizontal, DS.s4)
        .padding(.top, DS.s4)
        .padding(.bottom, DS.s3)
    }

    // MARK: 结果列表

    @ViewBuilder
    private var resultList: some View {
        if viewModel.entries.isEmpty {
            if viewModel.isSearching {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.query.isEmpty {
                emptyHint
            } else {
                ContentUnavailableView(
                    "无结果",
                    systemImage: "magnifyingglass",
                    description: Text("换个关键词试试")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: SearchPanelMetrics.resultSpacing) {
                        ForEach(Array(viewModel.entries.enumerated()), id: \.element.id) { index, entry in
                            SearchResultRow(
                                entry: entry,
                                thumbnail: viewModel.thumbnail(for: entry),
                                isSelected: index == viewModel.selectedIndex
                            ) {
                                viewModel.select(index)
                            }
                            .id(index)
                        }
                    }
                    .padding(.horizontal, DS.s3)
                    .padding(.vertical, DS.s1)
                }
                .onChange(of: viewModel.selectedIndex) { _, newIndex in
                    withAnimation(.none) {
                        proxy.scrollTo(newIndex, anchor: nil)
                    }
                }
            }
        }
    }

    private var emptyHint: some View {
        VStack(spacing: DS.s3) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: DS.font20, weight: .medium))
                .foregroundStyle(.quaternary)
            Text("搜索截图和剪贴板")
                .font(.system(size: DS.font13, weight: .regular))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
