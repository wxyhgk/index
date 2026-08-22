import AppKit
import Combine
import Quartz

/// 图库的空格 Quick Look。
///
/// 走 AppKit 的 QLPreviewPanel 而不是 SwiftUI 的 .quickLookPreview ——
/// 后者在 macOS 上有已知的键盘事件问题（空格关不掉、方向键不翻页）。
/// QLPreviewPanel 的接管是标准责任链模式：面板沿 key window 的 responder chain
/// 找应答 acceptsPreviewPanelControl 的对象，GalleryWindowController 应答后
/// 通过 begin/endPreviewPanelControl 把 dataSource/delegate 转交到这里。
///
/// 取舍：预览项用**原图**（originalURL），不含标注图层。渲染成品意味着为列表里
/// 每一张图合成全尺寸位图并写临时文件，方向键连续翻页时代价不可接受；
/// 原图是现成文件，面板直接吃 URL，零成本。标注请在编辑器或详情栏看。
@MainActor
final class QuickLookController: NSObject {

    /// 面板打开时的列表快照，与 currentPreviewItemIndex 一一对应。
    /// 面板开着时数据变化（删除、筛选）会重建快照并 reloadData。
    private var shots: [Shot] = []
    private var indexObservation: NSKeyValueObservation?
    private var selectionCancellable: AnyCancellable?
    private var storeCancellable: AnyCancellable?
    /// 同步进行中标记，切断「面板 → 选中 → 面板」的回环。
    private var isSyncing = false
    /// 可注入的读写源，默认 shared，单测可替。
    var store: ShotStore = .shared
    private var viewModel: GalleryViewModel = .shared

    override init() { super.init() }

    init(store: ShotStore) {
        self.store = store
        self.viewModel = .resolve(for: store)
        super.init()
    }

    var panelIsVisible: Bool {
        QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible
    }

    /// 空格：开/关。
    func toggle() {
        panelIsVisible ? close() : present()
    }

    func present() {
        QLPreviewPanel.shared().makeKeyAndOrderFront(nil)
    }

    func close() {
        guard panelIsVisible else { return }
        QLPreviewPanel.shared().orderOut(nil)
    }

    // MARK: - 由 GalleryWindowController 的 begin/endPreviewPanelControl 转交

    func attach(to panel: QLPreviewPanel) {
        shots = viewModel.displayShots
        panel.dataSource = self
        panel.delegate = self
        panel.currentPreviewItemIndex = selectedIndex() ?? 0

        // 面板自带的前后翻页按钮改 currentPreviewItemIndex → 反向同步网格选中。
        indexObservation = panel.observe(\.currentPreviewItemIndex) { panel, _ in
            MainActor.assumeIsolated {
                GalleryWindowController.shared.quickLook.syncSelection(toPanelIndex: panel.currentPreviewItemIndex)
            }
        }
        // 网格里点选 / 键盘导航 → 面板跟着换页。多选时面板预览主选中那张。
        selectionCancellable = GalleryWindowController.shared.selection.primaryIDPublisher
            .removeDuplicates()
            .sink { [weak self] _ in self?.syncPanelIndex() }
        // 搜索会话变化与库存快照是两条定向信号；不再依赖 ViewModel 转发所有 Store 写入。
        storeCancellable = Publishers.Merge(
            viewModel.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            store.libraryDidChangePublisher
        )
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.reloadShots() }
    }

    func detach(from panel: QLPreviewPanel) {
        indexObservation = nil
        selectionCancellable = nil
        storeCancellable = nil
        panel.dataSource = nil
        panel.delegate = nil
        shots = []
    }

    // MARK: - 双向同步

    private func selectedIndex() -> Int? {
        shots.firstIndex { $0.id == GalleryWindowController.shared.selection.primaryID }
    }

    /// 面板换页 → 网格选中跟随（滚动定位由网格监听 primaryID 完成）。
    /// 定位类场景语义：多选时翻页会收拢为面板当前张的单选。
    private func syncSelection(toPanelIndex index: Int) {
        guard !isSyncing, shots.indices.contains(index) else { return }
        isSyncing = true
        defer { isSyncing = false }
        GalleryWindowController.shared.selection.select(only: shots[index].id)
    }

    /// 网格选中变化 → 面板换页。
    private func syncPanelIndex() {
        guard !isSyncing, panelIsVisible, let index = selectedIndex() else { return }
        let panel = QLPreviewPanel.shared()!
        guard panel.currentPreviewItemIndex != index else { return }
        isSyncing = true
        defer { isSyncing = false }
        panel.currentPreviewItemIndex = index
    }

    private func reloadShots() {
        guard panelIsVisible else { return }
        let fresh = viewModel.displayShots
        guard fresh != shots else { return }
        shots = fresh
        if shots.isEmpty {
            close()
            return
        }
        let panel = QLPreviewPanel.shared()!
        panel.reloadData()
        panel.currentPreviewItemIndex = selectedIndex() ?? 0
    }
}

// MARK: - 数据源

extension QuickLookController: @preconcurrency QLPreviewPanelDataSource {

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        shots.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        guard shots.indices.contains(index) else { return nil }
        return store.originalURL(for: shots[index]) as NSURL
    }
}

// MARK: - 委托：面板打开期间的键盘

extension QuickLookController: QLPreviewPanelDelegate {

    /// 面板不处理的按键会转到这里。方向键交给统一的网格导航（选中变了会
    /// 反过来驱动面板换页），空格再按一次关面板 —— 和 Finder 行为一致。
    ///
    /// AppKit 在主线程回调；只把值类型的 keyCode 带进 assumeIsolated，
    /// 避免非 Sendable 的 NSEvent 跨隔离告警。
    nonisolated func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard let event, event.type == .keyDown else { return false }
        let keyCode = event.keyCode
        return MainActor.assumeIsolated {
            switch keyCode {
            case KeyCode.space:
                close()
                return true
            case KeyCode.left:
                GalleryWindowController.shared.keyboard.moveSelection(by: -1)
                return true
            case KeyCode.right:
                GalleryWindowController.shared.keyboard.moveSelection(by: 1)
                return true
            case KeyCode.up:
                GalleryWindowController.shared.keyboard.moveSelection(by: -GalleryWindowController.shared.keyboard.columnCount())
                return true
            case KeyCode.down:
                GalleryWindowController.shared.keyboard.moveSelection(by: GalleryWindowController.shared.keyboard.columnCount())
                return true
            default:
                return false
            }
        }
    }
}
