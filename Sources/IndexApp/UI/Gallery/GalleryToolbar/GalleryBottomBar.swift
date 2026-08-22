import SwiftUI
import AppKit

// ============================================================
// MARK: - 底部 bar
//
// 左侧：操作按钮组（导入/截图/布局/详情栏/更多）
// 居中：搜索框（ZStack 绝对居中，不受左侧按钮宽度影响）
// ============================================================

struct GalleryBottomBar: View {

    @Binding var showInspector: Bool
    @Binding var destinationID: String

    @ObservedObject private var viewModel: GalleryViewModel
    @ObservedObject private var imageImporter = ImageImportCoordinator.shared
    @ObservedObject private var appsNavigation = AppsNavigationState.shared
    @ObservedObject private var collectionsNavigation = CollectionsNavigationState.shared
    @State private var isImportingLibrary = false

    @AppStorage("galleryLayout") private var layout = GalleryLayoutKind.grid
    @AppStorage("galleryZoom") private var zoom = 200.0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        showInspector: Binding<Bool>,
        destinationID: Binding<String>,
        viewModel: GalleryViewModel = .shared
    ) {
        self._showInspector = showInspector
        self._destinationID = destinationID
        _viewModel = ObservedObject(wrappedValue: viewModel)
    }

    var body: some View {
        ZStack {
            // 搜索框绝对居中
            GallerySearchField(viewModel: viewModel)

            // 按钮分布到两边：左侧主要操作，右侧辅助操作
            HStack(spacing: DS.s2) {
                leftControls
                Spacer()
                rightControls
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: DS.Shell.bottomBarHeight)
        .padding(.horizontal, DS.Shell.windowMargin)
        .layoutPriority(1)
    }

    // MARK: - 左侧：主要操作

    private var leftControls: some View {
        Group {
            if destinationID == LibraryDestination.destinationID {
                importButton
                newMarkdownButton
            }
            if showsPrimaryCaptureButton {
                captureButton
            }
        }
    }

    private var newMarkdownButton: some View {
        Button {
            viewModel.createMarkdownCard()
        } label: {
            Label("Markdown", systemImage: "text.badge.plus")
                .font(.system(size: DS.font13, weight: .medium))
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help("新建 Markdown 卡片")
        .accessibilityLabel("新建 Markdown 卡片")
    }

    // MARK: - 右侧：辅助操作

    private var rightControls: some View {
        Group {
            if showsGridControls {
                layoutPicker
            }
            if showsInspectorToggle {
                inspectorToggle
            }
            moreMenu
        }
    }

    private var showsPrimaryCaptureButton: Bool {
        destinationID == LibraryDestination.destinationID
            || destinationID == AppsDestination.destinationID
            || destinationID == CollectionsDestination.destinationID
    }

    private var showsGridControls: Bool {
        if destinationID == AppsDestination.destinationID { return appsNavigation.isDrilled }
        if destinationID == CollectionsDestination.destinationID { return collectionsNavigation.isDrilled }
        return true
    }

    private var showsInspectorToggle: Bool {
        if destinationID == AppsDestination.destinationID { return appsNavigation.isDrilled }
        if destinationID == CollectionsDestination.destinationID { return collectionsNavigation.isDrilled }
        return true
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
                let report = try await ShotStore.shared.importPortableLibrary(at: directory)
                AppAlert.info("导入完成", message: report.summary)
            } catch {
                AppAlert.info("导入失败", message: error.localizedDescription)
            }
        }
    }

    private var layoutPicker: some View {
        Picker("显示模式", selection: Binding(
            get: { layout },
            set: { newValue in
                withAnimation(DS.Motion.standard(reduced: reduceMotion)) { layout = newValue }
            }
        )) {
            ForEach(GalleryLayoutKind.allCases, id: \.self) { kind in
                Image(systemName: kind.symbol).tag(kind)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help("网格：整齐等高，超出裁切；瀑布：等宽不裁切，完整显示长图")
    }

    private var inspectorToggle: some View {
        Button {
            showInspector.toggle()
        } label: {
            Image(systemName: "sidebar.trailing")
        }
        .buttonStyle(.shellIcon(active: showInspector))
        .help(showInspector ? "隐藏详情栏" : "显示详情栏")
        .accessibilityLabel("详情栏")
    }

    private var moreMenu: some View {
        Menu {
            if destinationID == LibraryDestination.destinationID
                || (destinationID == AppsDestination.destinationID && appsNavigation.isDrilled)
                || (destinationID == CollectionsDestination.destinationID
                    && collectionsNavigation.isDrilled) {
                Picker("缩略图大小", selection: $zoom) {
                    Text("小").tag(160.0)
                    Text("中").tag(220.0)
                    Text("大").tag(300.0)
                }
                .pickerStyle(.inline)
            } else if !showsPrimaryCaptureButton {
                Button("开始截图") { CaptureCoordinator.shared.begin() }
            }
            Divider()
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
        GalleryWindowController.shared.mode.openSettings()
    }
}
