import SwiftUI
import AppKit

// MARK: - 浮动面板布局：自绘顶栏 / 侧栏 / 网格 / 详情栏
//
// 布局参考用户提供的设计稿：**全定制窗口 chrome + 浮在深底上的圆角面板**。
// 顶栏自绘（GalleryTopBar），侧栏与详情栏是浮起的卡片（floatingPanel），
// 面板之间留出可见的缝，缝里露出的是窗口底色（`DS.windowBase`）。
//
// 为什么放弃 `NavigationSplitView` + `.inspector`：那两个 API 给的是**齐平分栏**
//（系统材质、系统分隔线、栏与栏之间没有间隙），而设计稿要的是彼此分离的浮起面板。
// 代价与收获都要说清楚：
//   · 丢掉：系统侧边栏材质与 vibrancy、可拖的分隔条、系统 inspector 动画。
//     侧边栏宽度改成固定值（`DS.Shell.sidebarWidth`）—— 顺手也就没有了
//     「拖分隔条时每帧重算」这条老路。
//   · 丢掉：`.searchable` 桥进窗口工具栏那条路（工具栏整个取消了）。
//     搜索改为自绘，实现在 GalleryTopBar，功能一件不少（见那边的文件注释）。
//   · 换来：外壳完全由我们自己排版，红绿灯之外没有任何系统 chrome。
//
// 本文件只剩窗口壳：模式分支（图库 / 编辑器）+ 四块的位置关系。
// 各块的实现在 GalleryTopBar / GalleryPageHeader / GallerySidebar / GalleryGrid /
// GalleryShell（浮动面板容器 + GalleryInspectorPanel）。

struct GalleryView: View {

    /// 窗口模式（图库 / 编辑器），整窗切换的依据。
    @ObservedObject private var mode = GalleryWindowMode.shared

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

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // 单窗口双模式（Snagit 的 Editor/Library）：编辑模式时整窗切到编辑器，
        // 返回图库 = `mode.returnToGallery()`（选中状态原样保留）。
        // Shot 值按 ID **现查** —— store 更新后编辑器拿到的永远是最新值。
        Group {
            if let shot = mode.resolveEditingShot() {
                EditorView(shot: shot)
                    // 换图 = 换 editingShotID；靠 identity 变化整个重建编辑器
                    // （重新走 onAppear → load，清撤销栈，与重开行为一致）。
                    .id(shot.id)
            } else {
                gallery
            }
        }
        .onReceive(ShotStore.shared.objectWillChange) { _ in
            // objectWillChange 发在变更**之前**，转一拍再查库。
            // 正在编辑的 shot 被删（自动清理等）时退回图库。
            DispatchQueue.main.async { closeEditorIfShotDeleted() }
        }
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
                GalleryTopBar(showInspector: $showInspector)

                HStack(alignment: .top, spacing: DS.Shell.panelGap) {
                    sidebarPanel
                    content
                    if showInspector {
                        GalleryInspectorPanel(isPresented: $showInspector)
                            .frame(width: DS.Shell.inspectorWidth)
                            // 从右侧滑入 / 滑出。ReduceMotion 下由下面那条
                            // `.animation(reduced:)` 降级成短 easeOut，不是硬切。
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .padding(.horizontal, DS.Shell.windowMargin)
                .padding(.bottom, DS.Shell.windowMargin)
            }
        }
        // 顶栏要自己接管标题栏那一条：窗口是 fullSizeContentView + 透明标题栏，
        // 内容伸到红绿灯底下，避让由 `DS.Shell.trafficLightInset` 在顶栏内部完成。
        .ignoresSafeArea(.container, edges: .top)
        .animation(DS.Motion.standard(reduced: reduceMotion), value: showInspector)
        .frame(minWidth: 1000, minHeight: 600)
    }

    /// 左侧：图标轨（设计稿 §2）+ 可折叠标签面板（§3）。
    ///
    /// 这一层**只负责把它摆在最左**，一个尺寸都不给：宽度（56 / 168 / 缝）、
    /// 折叠状态、两块各自的 `.floatingPanel()` 全在 `GalleryLeftPanels` 里 ——
    /// 展开与收起会让整块的宽度从 232 变成 56，把宽度写在这里就等于要求外壳
    /// 知道折叠状态，那是本视图刻意不订阅的东西（见上面关于 @State 的注释）。
    private var sidebarPanel: some View {
        GalleryLeftPanels()
    }

    /// 中间内容区：页头（大标题 + 计数 + 筛选胶囊）+ 网格。
    ///
    /// **这里对网格什么都不做** —— 它直接坐在窗口底色上，和设计稿一致（卡片浮在
    /// 深底上，中间区域不是一块浮起的纸）。上一轮为了让网格自铺的那层不透明画布
    /// 读起来像「浮起的一块」而临时加过一个 `clipShape(radiusFloating)`，
    /// 网格改版把画布交还窗口底色之后它已经没有对象可裁，删掉了。
    ///
    /// 仍然不许破坏的两件事：
    ///   · 宽度感知在网格内部，父层一个每帧 state 都不写；
    ///   · 网格底下必须是不透明的 —— 现在由本文件 `gallery` 里那层 `DS.windowBase`
    ///     负责（窗口也没开 `isOpaque = false`），别在这一层再补一块底色。
    private var content: some View {
        VStack(alignment: .leading, spacing: DS.s3) {
            GalleryPageHeader()
                .padding(.horizontal, DS.s2)
            GalleryGrid()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
