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
        let hosting = NSHostingController(rootView: GalleryView())
        // 把 SwiftUI 的 .searchable / .toolbar 桥进 NSWindow 的工具栏，
        // 否则搜索框会缩在内容区里而不是标题栏。
        hosting.sceneBridgingOptions = [.toolbars]

        let window = NSWindow(contentViewController: hosting)
        window.title = "MacShot 图库"
        window.setContentSize(NSSize(width: 1240, height: 760))
        // fullSizeContentView + .unified：内容伸到标题栏底下，工具栏和标题同一条。
        // **不要换成 .hiddenTitleBar** —— 搜索框是靠上面那行 sceneBridgingOptions
        // 桥进窗口工具栏的，藏掉标题栏会把它踢回内容区。
        //
        // 也**没有**设 `isOpaque = false` + `backgroundColor = .clear`。
        // 那对组合是「让侧边栏真的透出桌面」的开关，代价是：窗口里任何一块没人上色的
        // 区域都会直接透出壁纸。中栏画布已经不透明了（GalleryGrid 的
        // underPageBackgroundColor），但详情栏 / sheet / 空态那几块的底不归本文件管，
        // 而这台机器上无法把图库窗口截到（窗口不在可捕获的 Space 上），
        // 「实测确认没有透壁纸」这一步做不了。没验证过就不开 —— 透壁纸是整窗级事故，
        // 不是局部瑕疵。要开的前提写在交付报告里。
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.toolbarStyle = .unified
        // 记住窗口位置与大小；首次启动没有记录时才居中。
        if !window.setFrameUsingName("MacShotGallery") {
            window.center()
        }
        _ = window.setFrameAutosaveName("MacShotGallery")
        super.init(window: window)

        GalleryKeyboard.shared.install()

        // 单窗口双模式（Editor/Library）：编辑中把标题换成「标注 — 出处」，
        // 返回图库时恢复；进入编辑瞬间若 Quick Look 面板开着，顺手收掉 ——
        // 编辑器有自己的空格语义，面板留着只会盖住画布。
        // 模式模型只存 ID，来源摘要按 ID 现查（$editingShotID 发布的是新值，
        // 此刻属性本身还没写入，不能经由 resolveEditingShot 取）。
        editingCancellable = GalleryWindowMode.shared.$editingShotID
            .sink { [weak self] id in
                let summary = id
                    .flatMap { GalleryWindowMode.resolveShot(id: $0) }?
                    .sourceSummary
                self?.window?.title = summary.map { "标注 — \($0)" } ?? "MacShot 图库"
                if id != nil {
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
