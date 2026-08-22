import SwiftUI

// MARK: - Option+Space 全局搜索面板（苹果黑白风）
//
// 设计原则：
//   · 图标驱动：SF Symbols ultraLight，能用图标就不用文字
//   · 纯灰度：primary / secondary / tertiary / quaternary，无彩色
//   · 极简：大量留白，圆角 12，毛玻璃
//   · 弹出动画：缩放 0.96→1 + 透明度
//
// 文件布局：
//   · SearchPanelView          本文件：骨架 + 搜索框 + 空态
//   · SearchResultRow          单行结果
//   · SearchPreviewPanel       右侧预览 + 操作

struct SearchPanelView: View {
    @ObservedObject var viewModel: SearchPanelViewModel
    @FocusState private var searchFocused: Bool
    @State private var appeared = false

    var body: some View {
        HStack(spacing: 0) {
            listSection
            Divider()
                .frame(height: 360)
            SearchPreviewPanel(viewModel: viewModel)
                .frame(width: 240)
        }
        .frame(width: 640, height: 420)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.white.opacity(0.06), lineWidth: 0.5)
        }
        .scaleEffect(appeared ? 1 : 0.96)
        .opacity(appeared ? 1 : 0)
        .onAppear {
            searchFocused = true
            withAnimation(.spring(response: 0.22, dampingFraction: 0.88)) {
                appeared = true
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

    // MARK: 搜索框

    private var searchBar: some View {
        HStack(spacing: DS.s3) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 18, weight: .ultraLight))
                .foregroundStyle(.secondary)
            TextField("", text: $viewModel.query)
                .textFieldStyle(.plain)
                .font(.system(size: 20, weight: .light))
                .focused($searchFocused)
                .onChange(of: viewModel.query) { _ in
                    viewModel.searchChanged()
                }
            if !viewModel.query.isEmpty {
                Button {
                    viewModel.clear()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .light))
                        .foregroundStyle(.tertiary)
                        .frame(width: 18, height: 18)
                        .background(.primary.opacity(0.06), in: Circle())
                }
                .buttonStyle(.plain)
            }
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
                    "",
                    systemImage: "magnifyingglass",
                    description: Text("无结果")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 1) {
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
                    .padding(.horizontal, DS.s2)
                    .padding(.vertical, DS.s1)
                }
                .onChange(of: viewModel.selectedIndex) { newIndex in
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
                .font(.system(size: 24, weight: .ultraLight))
                .foregroundStyle(.quaternary)
            Text("搜索截图和剪贴板")
                .font(.system(size: 13, weight: .light))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
