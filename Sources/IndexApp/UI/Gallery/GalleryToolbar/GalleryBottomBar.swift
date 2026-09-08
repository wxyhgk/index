import SwiftUI
import AppKit

// ============================================================
// MARK: - 底部工具栏
//
// 搜索是内容浏览的高频入口，固定在底栏视觉中心；主要动作和辅助动作
// 分列两侧，切换页面时搜索不会挤压顶层导航。
// ============================================================

struct GalleryBottomBar: View {

    @Binding var showInspector: Bool
    @Binding var destinationID: String

    @ObservedObject private var viewModel: GalleryViewModel
    @ObservedObject private var imageImporter = ImageImportCoordinator.shared
    @ObservedObject private var destinationChrome: GalleryDestinationChromeState
    private let destinationRegistry: GalleryDestinationRegistry
    @State private var isImportingLibrary = false

    @AppStorage(PagePreferences.galleryLayout.key)
    private var layout = PagePreferences.galleryLayout.enumDefault(as: GalleryLayoutKind.self)
    @AppStorage(PagePreferences.galleryZoom.key)
    private var zoom = PagePreferences.galleryZoom.defaultValue

    @Environment(\.galleryPageCommands) private var pageCommands
    @EnvironmentObject private var selection: GallerySelection

    init(
        showInspector: Binding<Bool>,
        destinationID: Binding<String>,
        viewModel: GalleryViewModel = .shared,
        destinationRegistry: GalleryDestinationRegistry,
        destinationChrome: GalleryDestinationChromeState
    ) {
        self._showInspector = showInspector
        self._destinationID = destinationID
        _viewModel = ObservedObject(wrappedValue: viewModel)
        self.destinationRegistry = destinationRegistry
        _destinationChrome = ObservedObject(wrappedValue: destinationChrome)
    }

    var body: some View {
        Group {
            if currentChrome.showsSearch {
                HStack(spacing: DS.s3) {
                    leftControls
                        .frame(maxWidth: .infinity, alignment: .leading)

                    GallerySearchField(viewModel: viewModel)
                        .frame(width: DS.Shell.searchWidth)

                    rightControls
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            } else {
                HStack(spacing: DS.s2) {
                    leftControls
                    Spacer(minLength: DS.s2)
                    rightControls
                }
            }
        }
        .padding(.horizontal, DS.s2)
        .frame(maxWidth: .infinity)
        .frame(height: DS.Shell.bottomBarPanelHeight)
        .floatingPanel(radius: DS.radiusPanel, level: .overlay)
        .padding(.horizontal, DS.Shell.windowMargin)
        .padding(.vertical, DS.Shell.windowMargin)
        .frame(height: DS.Shell.bottomBarHeight)
        .layoutPriority(1)
    }

    // MARK: - 左侧：主要操作

    private var leftControls: some View {
        HStack(spacing: DS.s1) {
            if currentChrome.showsImportControl {
                importButton
            }
            if currentChrome.showsMarkdownControl {
                newContentMenu
            }
            if currentChrome.showsCaptureControl {
                captureButton
            }
        }
    }

    // MARK: - 右侧：辅助操作

    private var rightControls: some View {
        HStack(spacing: DS.s1) {
            // 瀑布流已退出公开布局，只剩一个选项时不显示无法操作的分段控件。
            if currentChrome.showsLayoutControls,
               GalleryLayoutKind.allCases.count > 1 {
                layoutPicker
            }
            if currentChrome.showsInspector {
                inspectorToggle
            }
            moreMenu
        }
    }

    private var newContentMenu: some View {
        Menu {
            Button {
                viewModel.createMarkdownCard()
            } label: {
                Label("Markdown 便签", systemImage: "text.badge.plus")
            }
            Button {
                viewModel.createCodeCard()
            } label: {
                Label("代码片段", systemImage: "chevron.left.forwardslash.chevron.right")
            }
        } label: {
            Label("新建内容", systemImage: "plus")
                .font(.system(size: DS.font13, weight: .medium))
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help("新建便签或代码片段")
        .accessibilityLabel("新建内容")
    }

    private var currentChrome: GalleryDestinationChrome {
        let fallback = destinationRegistry.resolve(id: destinationID)?.defaultChrome ?? .standard
        return destinationChrome.resolve(for: destinationID, fallback: fallback)
    }

    private var captureButton: some View {
        Button {
            CaptureCoordinator.shared.begin()
        } label: {
            Label("截图", systemImage: "viewfinder")
                .font(.system(size: DS.font13, weight: .semibold))
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .help("开始截图（⌃⌘A）")
        .accessibilityLabel("开始截图")
    }

    private var importButton: some View {
        Menu {
            Button("导入图片…") {
                guard let urls = SystemNavigator.chooseImageFiles(), !urls.isEmpty else { return }
                viewModel.reset()
                imageImporter.enqueue(urls)
            }
            Button("导入便携图库…") {
                importPortableLibrary()
            }
            .disabled(isImportingLibrary)
        } label: {
            if imageImporter.isImporting || isImportingLibrary {
                ProgressView()
                    .controlSize(.small)
            } else {
                Label("导入", systemImage: "square.and.arrow.down")
                    .font(.system(size: DS.font13, weight: .medium))
            }
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .controlSize(.small)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("导入图片或便携图库")
        .accessibilityLabel(imageImporter.isImporting || isImportingLibrary ? "正在导入" : "导入")
    }

    private func importPortableLibrary() {
        guard let directory = SystemNavigator.chooseDirectory() else { return }
        isImportingLibrary = true
        Task {
            defer { isImportingLibrary = false }
            do {
                let report = try await viewModel.store.importPortableLibrary(at: directory)
                AppAlert.info("导入完成", message: report.summary)
            } catch {
                AppAlert.info("导入失败", message: error.localizedDescription)
            }
        }
    }

    private var layoutPicker: some View {
        GalleryLayoutPicker(layoutMode: $layout)
    }

    private var inspectorToggle: some View {
        Button {
            showInspector.toggle()
        } label: {
            Image(systemName: "sidebar.trailing")
        }
        .buttonStyle(.shellIcon(active: inspectorIsPresented))
        .disabled(!inspectorIsAvailable)
        .help(inspectorHelp)
        .accessibilityLabel("详情栏")
    }

    private var inspectorIsAvailable: Bool {
        currentChrome.canPresentInspector(hasSelection: !selection.selectedIDs.isEmpty)
    }

    private var inspectorIsPresented: Bool {
        inspectorIsAvailable && showInspector
    }

    private var inspectorHelp: String {
        guard inspectorIsAvailable else { return "选择一项后查看详情" }
        return showInspector ? "隐藏详情栏" : "显示详情栏"
    }

    private var moreMenu: some View {
        Menu {
            if currentChrome.showsThumbnailSizePicker {
                Picker("缩略图大小", selection: $zoom) {
                    Text("小").tag(DS.thumbnailSmall)
                    Text("中").tag(DS.thumbnailMedium)
                    Text("大").tag(DS.thumbnailLarge)
                }
                .pickerStyle(.inline)
                Divider()
            }
            Button("设置…") { openSettings() }
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.button)
        .buttonStyle(.shellIcon)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("更多")
    }

    private func openSettings() {
        pageCommands.openSettings()
    }
}
