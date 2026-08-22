import SwiftUI
import AppKit

// MARK: - 窗口壳：自绘顶栏 / 中间内容 / 右侧详情栏
//
// 布局是**全定制窗口 chrome**：红绿灯之外没有任何系统 chrome。
// 顶栏自绘（GalleryTopBar，含顶层选项、搜索、视图控制），中间和右侧由
// **当前选中的那个选项**提供（见 GalleryDestination），详情栏是浮起的圆角卡片，
// 它与内容之间留出可见的缝，缝里露出的是窗口底色（`DS.windowBase`）。
//
// 为什么不用 `NavigationSplitView` + `.inspector`：那两个 API 给的是**齐平分栏**
//（系统材质、系统分隔线、栏与栏之间没有间隙），而这里要的是彼此分离的浮起面板。
// 代价与收获：
//   · 丢掉：系统侧边栏材质与 vibrancy、可拖的分隔条、系统 inspector 动画。
//     顺带也就没有了「拖分隔条时每帧重算」这条老路。
//   · 丢掉：`.searchable` 桥进窗口工具栏那条路（工具栏整个取消了）。
//     搜索改为自绘，实现在 GalleryTopBar，功能一件不少（见那边的文件注释）。
//   · 换来：外壳完全由我们自己排版。
//
// 左侧曾经有一整条侧边栏放顶层选项，后来搬到了顶栏的分段控件 ——
// 232pt 的固定栏正好吃掉整整一列缩略图，而顶栏本来就在那儿（理由见
// `GalleryTopBar.destinationTabs`）。
//
// 本文件只剩窗口壳：模式分支（图库 / 编辑器 / 设置）+ 三块的位置关系。

struct GalleryView: View {

    /// 窗口模式（图库 / 编辑器），整窗切换的依据。由 controller 注入。
    @EnvironmentObject var mode: GalleryWindowMode

    /// 存储订阅：编辑中的 shot 被删时退回图库。注入式，默认走 ShotStore.shared。
    @ObservedObject private var store: ShotStore
    private let viewModel: GalleryViewModel
    /// 编辑器会话的设置切片。窗口装配点（GalleryWindowController）注入，
    /// 沿 GalleryView → EditorModeView → EditorView → EditorModel 传递。
    private let styleStore: any AnnotationStylePreferences

    init(
        styleStore: any AnnotationStylePreferences,
        store: ShotStore = .shared,
        viewModel: GalleryViewModel? = nil
    ) {
        _store = ObservedObject(wrappedValue: store)
        let resolvedViewModel = viewModel
            ?? .resolve(for: store)
        self.viewModel = resolvedViewModel
        self.styleStore = styleStore
    }

    // ⚠️ 这里**没有** store / selection 的订阅，也**没有**任何宽度状态，两条都是有意的。
    //
    // 宽度：本视图是四块的共同父层，在这一层放一个「随网格宽度每帧变化」的 @State
    //（曾经的 gridWidth）会让整棵外壳每帧重算 —— 宽度感知住在 GalleryGrid 内部
    //（见 GalleryGrid.widthReader），别搬回来。
    //
    // store / selection：详情栏的内容解析要扫两趟全列表，那份订阅现在住在
    // `GalleryInspectorPanel` 里。放在这一层的话，任何一次选中变化都要重算整棵外壳的
    // body（顶栏、胶囊行、面板容器全部跟着走一遍），而真正需要重算的只有详情栏。
    // 现在本视图的 body 只依赖 `mode` 和 `showInspector` 两个值。

    /// 详情栏开关，跨启动记住。顶栏的开关按钮和详情面板右上角的 ✕ 都写它。
    @AppStorage("galleryInspectorShown") private var showInspector = true

    /// 选中的侧边栏选项。存 id 不存序号 —— 插入新选项不会让用户上次停留的位置漂移；
    /// 解析不到（选项被移除、旧值）时 `resolve` 退回第一个。
    @AppStorage("galleryDestination") private var destinationID = "destination.library"

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // 单窗口多模式：图库 / 编辑器 / 设置，整窗切换而不是弹窗。
        // 返回图库 = `mode.returnToGallery()`（选中状态原样保留）。
        // Shot 值按 ID **现查** —— store 更新后编辑器拿到的永远是最新值。
        Group {
            if mode.isSettings {
                settingsMode
            } else if let shot = mode.resolveEditingShot() {
                // 编辑会话按 shot ID 重建；Filmstrip 由稳定外壳保留，避免切图时
                // 同时丢失其数据和横向滚动位置。
                EditorModeView(shot: shot, styleStore: styleStore)
            } else {
                gallery
            }
        }
        .onReceive(store.libraryDidChangePublisher) {
            // 只订库存快照完成信号；修订自动保存与分页不再让整个窗口外壳失效。
            closeEditorIfShotDeleted()
        }
    }

    /// 设置模式：与编辑器同样的整窗切换，左上角一个返回按钮。
    /// 顶栏那一条留给标题与返回，红绿灯的避让沿用 `DS.Shell.trafficLightInset`。
    private var settingsMode: some View {
        ZStack(alignment: .top) {
            Color(nsColor: DS.windowBase).ignoresSafeArea()

            VStack(spacing: 0) {
                HStack(spacing: DS.s3) {
                    Button {
                        mode.returnToGallery()
                    } label: {
                        Label("图库", systemImage: "chevron.left")
                            .font(.system(size: DS.font13, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.escape, modifiers: [])

                    Text("设置")
                        .font(.system(size: DS.font15, weight: .semibold))

                    Spacer()
                }
                .padding(.leading, DS.Shell.trafficLightInset)
                .padding(.trailing, DS.Shell.windowMargin)
                .frame(height: 48)

                SettingsView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, DS.s3)
                    .padding(.bottom, DS.s3)
            }
        }
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: 1000, minHeight: 600)
    }

    private var gallery: some View {
        ZStack(alignment: .top) {
            // 窗口底色。**这一层必须不透明** —— 面板之间的缝露出的是它，
            // 而窗口本身没有开 `isOpaque = false`（那会透出壁纸，是整窗级事故，
            // 理由写在 GalleryWindowController 里）。同一个 NSColor 也赋给了
            // `window.backgroundColor`，live resize 时不会闪出第二种灰。
            Color(nsColor: DS.windowBase)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                GalleryTopBar(
                    destinationID: $destinationID
                )

                // 中间内容 │ 右侧面板 —— 两块都由**选中的那个选项**提供
                // （见 GalleryDestination）。容器不认识任何一个具体选项装了什么。
                //
                // 顶层选项从左侧一整条侧边栏搬到了顶栏（理由见 GalleryTopBar
                // 的 `destinationTabs`），于是这一行少了一栏，中间直接从窗口左边缘开始。
                HStack(alignment: .top, spacing: DS.Shell.panelGap) {
                    let destination = GalleryDestinationRegistry.shared.resolve(id: destinationID)

                    (destination?.content() ?? AnyView(EmptyView()))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                    if showInspector, let inspector = destination?.inspector() {
                        inspector
                            .frame(width: DS.Shell.inspectorWidth)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .padding(.horizontal, DS.Shell.windowMargin)

                GalleryBottomBar(
                    showInspector: $showInspector,
                    destinationID: $destinationID,
                    viewModel: viewModel
                )
                .padding(.bottom, DS.Shell.windowMargin)
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        // 顶栏要自己接管标题栏那一条：窗口是 fullSizeContentView + 透明标题栏，
        // 内容伸到红绿灯底下，避让由 `DS.Shell.trafficLightInset` 在顶栏内部完成。
        .ignoresSafeArea(.container, edges: .top)
        .animation(DS.Motion.standard(reduced: reduceMotion), value: showInspector)
        .frame(minWidth: 1000, minHeight: 600)
        // ZStack 下所有 tab 始终存在，onAppear/onDisappear 不再可靠。
        // scope 切换统一在这里处理：destinationID 变化时激活对应 scope。
        .task {
            activateScope(for: destinationID)
        }
        .onChange(of: destinationID) { _, newID in
            activateScope(for: newID)
        }
    }

    /// 按 destinationID 激活对应的 GalleryContentScope。
    /// 只有需要固定范围的 destination（如录屏）才有非 .library scope。
    private func activateScope(for id: String) {
        guard let destination = GalleryDestinationRegistry.shared.resolve(id: id) else { return }
        destination.contentScope.activate(in: viewModel)
    }


    /// 正在编辑的记录已不存在（图库外的删除 / 清理）→ 退回图库模式。
    /// 编辑一条已删除的记录没有意义，保存也无处可去。
    /// 「不存在」的判定就是 `resolveEditingShot()` 按 ID 现查失败 ——
    /// 与 body 的分支同一个口径，不会出现「模式在编辑、视图在图库」的错位。
    private func closeEditorIfShotDeleted() {
        guard mode.isEditing, mode.resolveEditingShot() == nil else { return }
        mode.returnToGallery()
    }
}
