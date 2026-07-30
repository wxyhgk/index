import SwiftUI
import AppKit

// MARK: - 三栏布局：侧边栏（筛选） / 网格 / 详情
//
// 布局参考 Snagit Library：左侧按 分类 / 应用 导航（带计数和真实 App 图标），
// 中间大缩略图网格 + 底部缩放条，右侧详情。NavigationSplitView 自带侧边栏
// 毛玻璃材质和折叠行为，搜索框走 .searchable 进窗口工具栏。
//
// 本文件只剩窗口壳：模式分支（图库 / 编辑器）、三栏装配、搜索与 inspector。
// 各栏的实现分别在 GallerySidebar / GalleryGrid / ShotDetailPane / MultiSelectionPane。

struct GalleryView: View {

    @ObservedObject private var store = ShotStore.shared
    @ObservedObject private var selection = GallerySelection.shared
    /// 窗口模式（图库 / 编辑器），整窗切换的依据。
    @ObservedObject private var mode = GalleryWindowMode.shared
    // 语义模式切换只在「开关已开 + 模型已就绪」时出现，所以要订阅这两个。
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var modelStore = CLIPModelStore.shared

    // ⚠️ 这里**没有**任何宽度状态，这是有意的。本视图是三栏的共同父层，
    // 在这一层放一个「随网格宽度每帧变化」的 @State（曾经的 gridWidth），
    // 拖 NavigationSplitView 的分隔条时每一帧都会重算 GalleryView.body，代价是：
    //   · `inspectorPane` 是 ViewBuilder 参数，**急切求值** ——
    //     `multiSelectedShots` / `selectedShot` 的三趟全列表扫描每帧各跑一遍；
    //   · 整条 searchable / toolbar / inspector 修饰器链每帧重建；
    //   · 最贵的一项：网格的入参每帧都不同 → GalleryGrid.body 必定重算 →
    //     每张可见卡片的 contextMenu 内容、draggable 载荷、preview 闭包
    //     跟着逐帧重求值（这几样都是急切求值的，见 GalleryGrid.cardBody）。
    // 宽度感知现在住在 GalleryGrid 内部（见 GalleryGrid.widthReader），
    // 失效范围收缩到网格子树，拖动分隔条时本视图的 body 一次都不重算。

    /// 详情栏（inspector）开关，跨启动记住。
    @AppStorage("galleryInspectorShown") private var showInspector = true

    private var semanticAvailable: Bool {
        settings.semanticSearch && modelStore.isReady
    }

    private var selectedShot: Shot? {
        // 语义结果可能不在常规列表（最近 500 张）里，两边都找。
        store.displayShots.first { $0.id == selection.primaryID }
            ?? store.shots.first { $0.id == selection.primaryID }
    }

    /// 多选时按展示顺序解析出的截图（选中集合里可能残留已删除的 ID，以解析结果为准）。
    private var multiSelectedShots: [Shot] {
        guard selection.isMultiple else { return [] }
        var picked = store.displayShots.filter { selection.isSelected($0.id) }
        let seen = Set(picked.compactMap(\.id))
        picked += store.shots.filter { shot in
            guard let id = shot.id else { return false }
            return selection.selectedIDs.contains(id) && !seen.contains(id)
        }
        return picked
    }

    var body: some View {
        // 单窗口双模式（Snagit 的 Editor/Library）：编辑模式时整窗切到编辑器，
        // 返回图库 = `mode.returnToGallery()`（选中状态原样保留）。
        // Shot 值按 ID **现查** —— store 更新后编辑器拿到的永远是最新值。
        // .searchable / .inspector / .toolbar 只挂在图库分支 ——
        // 编辑器模式下窗口工具栏不该出现搜索框和详情开关。
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
        .onReceive(store.objectWillChange) { _ in
            // objectWillChange 发在变更**之前**，转一拍再查库。
            // 正在编辑的 shot 被删（自动清理等）时退回图库。
            DispatchQueue.main.async { closeEditorIfShotDeleted() }
        }
    }

    private var gallery: some View {
        // 两栏（侧边栏 + 网格）+ 可开关的 inspector 详情栏 ——
        // 详情从 NavigationSplitView 的 detail 列挪出来，换取标准的
        // 「随时收起给网格让路」行为和系统自带的材质/分隔线。
        NavigationSplitView {
            GallerySidebar()
                .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 280)
        } detail: {
            GalleryGrid()
        }
        .inspector(isPresented: $showInspector) {
            inspectorPane
                .inspectorColumnWidth(min: 260, ideal: 300)
        }
        .searchable(
            text: $store.searchText,
            placement: .toolbar,
            prompt: store.semanticMode
                ? "描述画面内容，回车搜索（英文效果最好）"
                : "搜 App、标题、网址或截图里的字"
        )
        .onChange(of: store.searchText) { _, newValue in
            if store.semanticMode {
                // 语义搜索按回车触发；清空输入即恢复常规列表。
                if newValue.trimmingCharacters(in: .whitespaces).isEmpty {
                    store.clearSemanticResults()
                }
            } else {
                store.reload()
            }
        }
        .onSubmit(of: .search) {
            guard store.semanticMode else { return }
            Task { await store.runSemanticSearch() }
        }
        .toolbar {
            if semanticAvailable {
                ToolbarItem(placement: .primaryAction) {
                    Picker("搜索模式", selection: $store.semanticMode) {
                        Text("精确").tag(false)
                        Text("语义").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .help("精确：全文匹配文字与元数据；语义：用自然语言描述画面，按回车搜索")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showInspector.toggle()
                } label: {
                    Label("详情", systemImage: "sidebar.trailing")
                }
                .help(showInspector ? "隐藏详情栏" : "显示详情栏")
            }
        }
        .onChange(of: store.semanticMode) { _, semantic in
            if !semantic { store.clearSemanticResults() }
        }
        .frame(minWidth: 1000, minHeight: 600)
    }

    @ViewBuilder
    private var inspectorPane: some View {
        let multi = multiSelectedShots
        if multi.count > 1 {
            MultiSelectionPane(shots: multi)
        } else if let shot = selectedShot ?? multi.first {
            ShotDetailPane(shot: shot)
        } else {
            ContentUnavailableView(
                "未选择截图",
                systemImage: "photo.on.rectangle",
                description: Text("在网格中选择一张截图查看详情")
            )
        }
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
