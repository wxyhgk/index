import SwiftUI
import AppKit

// ============================================================
// MARK: - 搜索胶囊（从 GalleryTopBar 抽出，供顶栏/底栏复用）
//
// 精确 / 语义两种模式、⌘K 聚焦、清空按钮、scope 菜单。
// ============================================================

struct GallerySearchField: View {

    @ObservedObject var viewModel: GalleryViewModel
    @ObservedObject private var settings: AppSettings
    @ObservedObject private var modelStore = CLIPModelStore.shared

    @FocusState private var searchFocused: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(viewModel: GalleryViewModel = .shared, settings: AppSettings = .shared) {
        self._viewModel = ObservedObject(wrappedValue: viewModel)
        self._settings = ObservedObject(wrappedValue: settings)
    }

    private var semanticAvailable: Bool {
        settings.semanticSearch && modelStore.isReady
    }

    var body: some View {
        ZStack {
            Button {
                searchFocused = true
            } label: {
                Color.clear.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut("k", modifiers: .command)
            .accessibilityLabel("搜索截图")

            searchContent
        }
        .padding(.horizontal, DS.s3)
        .frame(maxWidth: DS.Shell.searchWidth)
        .frame(height: DS.Shell.searchHeight)
        .background(capsuleFill, in: Capsule())
        .overlay {
            Capsule().strokeBorder(
                searchFocused ? DS.accentStrokeFocus : capsuleStroke,
                lineWidth: searchFocused ? 1.5 : 1
            )
            .allowsHitTesting(false)
        }
        .animation(DS.Motion.micro(reduced: reduceMotion), value: searchFocused)
        .onChange(of: viewModel.searchText) { _, newValue in
            if viewModel.semanticMode {
                if newValue.trimmingCharacters(in: .whitespaces).isEmpty {
                    viewModel.clearSemanticResults()
                }
            } else {
                viewModel.scheduleExactSearch()
            }
        }
        .onChange(of: viewModel.semanticMode) { _, semantic in
            if semantic {
                viewModel.cancelPendingExactSearch()
            } else {
                viewModel.clearSemanticResults()
                viewModel.scheduleExactSearch()
            }
        }
    }

    private var searchContent: some View {
        HStack(spacing: DS.s2) {
            searchScope

            TextField("搜索", text: $viewModel.searchText, prompt: Text(searchPrompt))
                .textFieldStyle(.plain)
                .labelsHidden()
                .font(.system(size: DS.font13))
                .focused($searchFocused)
                .onSubmit {
                    guard viewModel.semanticMode else { return }
                    Task { await viewModel.runSemanticSearch() }
                }

            if !viewModel.searchText.isEmpty {
                Button {
                    viewModel.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: DS.font12))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清除搜索")
            } else if !searchFocused {
                shortcutBadge
            }
        }
    }

    private var searchPrompt: String {
        viewModel.semanticMode
            ? "描述画面内容，回车搜索（英文效果最好）"
            : "搜 App、标题、网址或截图里的字"
    }

    @ViewBuilder
    private var searchScope: some View {
        if semanticAvailable {
            Menu {
                Picker("搜索模式", selection: $viewModel.semanticMode) {
                    Text("精确匹配").tag(false)
                    Text("语义搜索").tag(true)
                }
                .pickerStyle(.inline)
            } label: {
                HStack(spacing: 1) {
                    Image(systemName: scopeSymbol)
                        .font(.system(size: DS.font13))
                    Image(systemName: "chevron.down")
                        .font(.system(size: DS.font7, weight: .bold))
                }
                .foregroundStyle(viewModel.semanticMode ? AnyShapeStyle(DS.accent)
                                                    : AnyShapeStyle(HierarchicalShapeStyle.secondary))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("精确：全文匹配文字与元数据；语义：用自然语言描述画面，按回车搜索")
        } else {
            Image(systemName: "magnifyingglass")
                .font(.system(size: DS.font13))
                .foregroundStyle(.secondary)
        }
    }

    private var scopeSymbol: String {
        viewModel.semanticMode ? "sparkle.magnifyingglass" : "magnifyingglass"
    }

    private var shortcutBadge: some View {
        Text("⌘K")
            .font(.system(size: DS.font11, weight: .medium))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, DS.s1 + 1)
            .padding(.vertical, DS.s1 / 2)
            .background(
                DS.badgeFill(scheme),
                in: RoundedRectangle(cornerRadius: DS.radiusChip, style: .continuous)
            )
            .accessibilityHidden(true)
    }

    private var capsuleFill: Color {
        DS.capsuleFill(scheme)
    }

    private var capsuleStroke: Color {
        DS.capsuleStroke(scheme)
    }
}
