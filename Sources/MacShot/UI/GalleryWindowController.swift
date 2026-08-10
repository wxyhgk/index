import AppKit
import Combine
import Quartz
import SwiftUI

@MainActor
final class GalleryWindowController: NSWindowController {

    static let shared = GalleryWindowController()

    /// 订阅编辑模式切换：改窗口标题 + 进编辑时收掉 Quick Look 面板。
    private var editingCancellable: AnyCancellable?

    private init() {
        // 没有 `sceneBridgingOptions = [.toolbars]` 了：窗口不再有工具栏，
        // 顶栏（logo / 搜索 / 控件组）整条由 SwiftUI 自绘，见 GalleryTopBar。
        let hosting = NSHostingController(rootView: GalleryView())

        let window = NSWindow(contentViewController: hosting)
        // 标题**藏起来但不清空**：窗口菜单、Mission Control、⌘` 切窗都读它，
        // 编辑模式下还会被换成「标注 — 出处」（见下面那个 sink）。
        window.title = "MacShot 图库"
        window.setContentSize(NSSize(width: 1240, height: 760))
        // 全定制 chrome：内容伸满整窗（含标题栏那一条），标题栏透明、标题不画，
        // 也不挂 NSToolbar —— 窗口上剩下的唯一系统件是红绿灯。
        // 红绿灯位置保留系统默认（不手动摆位），自绘内容靠
        // `DS.Shell.trafficLightInset`(80) 在顶栏内部避让。
        //
        // **仍然没有**设 `isOpaque = false` + `backgroundColor = .clear`。
        // 那对组合是「让面板真的透出桌面」的开关，代价是窗口里任何一块没人上色的
        // 区域都会直接透出壁纸 —— 而这套布局里「面板之间的缝」正是大片没有内容的区域。
        // 缝里露出的必须是窗口底色，所以底色由内容自己铺一层不透明的
        // `DS.windowBase`（见 GalleryView.gallery）。透壁纸是整窗级事故，不是局部瑕疵。
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // 窗口自己那层底也换成同一个 NSColor（SwiftUI 侧铺的是 `Color(nsColor:)`
        // 的同一实例）：默认的 windowBackgroundColor 比它亮一档，live resize 时
        // 会在还没上色的新边缘闪出一条更亮的灰。
        window.backgroundColor = DS.windowBase
        // 记住窗口位置与大小；首次启动没有记录时才居中。
        if !window.setFrameUsingName("MacShotGallery") {
            window.center()
        }
        _ = window.setFrameAutosaveName("MacShotGallery")
        super.init(window: window)

        GalleryKeyboard.shared.install()

        // 单窗口多模式（图库 / 编辑器 / 设置）：标题跟着模式走；
        // 进入编辑瞬间若 Quick Look 面板开着，顺手收掉 ——
        // 编辑器有自己的空格语义，面板留着只会盖住画布。
        // 模式模型只存 ID，来源摘要按 ID 现查（$mode 发布的是新值，
        // 此刻属性本身还没写入，不能经由 resolveEditingShot 取）。
        editingCancellable = GalleryWindowMode.shared.$mode
            .sink { [weak self] mode in
                switch mode {
                case .library:
                    self?.window?.title = "MacShot 图库"
                case .settings:
                    self?.window?.title = "MacShot 设置"
                case .editing(let id):
                    let summary = GalleryWindowMode.resolveShot(id: id)?.sourceSummary
                    self?.window?.title = summary.map { "标注 — \($0)" } ?? "MacShot 图库"
                    QuickLookController.shared.close()
                }
            }
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Quick Look 责任链接管
    //
    // QLPreviewPanel 沿 key window 的 responder chain 找愿意接管的对象。
    // 窗口控制器在链上，这里应答并把 dataSource/delegate 转交给 QuickLookController
    // —— Apple 文档（QLPreviewPanelController 非正式协议）里的标准做法。

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        true
    }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        QuickLookController.shared.attach(to: panel)
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        QuickLookController.shared.detach(from: panel)
    }

    // MARK: - Edit 菜单（⌘C/⌘A 走 responder chain）

    @objc func copy(_ sender: Any?) {
        // 仅在图库模式且有选中时复制成品（与右键/⌘C monitor 同一渲染口径）。
        // 不再以 firstResponder/keyWindow 守卫，文本框有选区时 NSTextView 先响应，冒泡到这里时自然是图片路径。
        guard GalleryWindowMode.shared.mode == .library else { return }
        let shots = GalleryBatch.selectedShots()
        guard !shots.isEmpty else { return }
        GalleryBatch.copyImages(shots)
    }

    @objc override func selectAll(_ sender: Any?) {
        guard GalleryWindowMode.shared.mode == .library else { return }
        Task {
            let ids = await ShotStore.shared.allMatchingIDs()
            GallerySelection.shared.selectAll(ids)
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(NSText.copy(_:)):
            return GalleryWindowMode.shared.mode == .library && !GallerySelection.shared.selectedIDs.isEmpty
        case #selector(selectAll(_:)):
            return GalleryWindowMode.shared.mode == .library
        default:
            return true
        }
    }

    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if let menuItem = item as? NSMenuItem {
            switch menuItem.action {
            case #selector(NSText.copy(_:)):
                return GalleryWindowMode.shared.mode == .library && !GallerySelection.shared.selectedIDs.isEmpty
            case #selector(selectAll(_:)):
                return GalleryWindowMode.shared.mode == .library
            default: break
            }
        }
        return true
    }

    func show(selecting shot: Shot? = nil) {
        ShotStore.shared.reload()
        if let shot {
            // 定位类场景：清空多选后单选目标。
            GallerySelection.shared.select(only: shot.id)
        }
        WindowRegistry.shared.present(self, dockIcon: true)
    }

    /// 图库外部的编辑入口（钉图「编辑标注」、滚动截图完成等）：
    /// 弹出图库窗口并直接进入编辑器模式。
    func showEditor(for shot: Shot) {
        show(selecting: shot)
        GalleryWindowMode.shared.openEditor(shotID: shot.id)
    }
}
