import AppKit
import Quartz
import SwiftUI

@MainActor
final class GalleryWindowController: NSWindowController {

    static let shared = GalleryWindowController()

    private init() {
        let hosting = NSHostingController(rootView: GalleryView())
        // 把 SwiftUI 的 .searchable / .toolbar 桥进 NSWindow 的工具栏，
        // 否则搜索框会缩在内容区里而不是标题栏。
        hosting.sceneBridgingOptions = [.toolbars]

        let window = NSWindow(contentViewController: hosting)
        window.title = "MacShot 图库"
        window.setContentSize(NSSize(width: 1240, height: 760))
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.toolbarStyle = .unified
        // 记住窗口位置与大小；首次启动没有记录时才居中。
        if !window.setFrameUsingName("MacShotGallery") {
            window.center()
        }
        _ = window.setFrameAutosaveName("MacShotGallery")
        super.init(window: window)

        GalleryKeyboard.shared.install()
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
            GallerySelection.shared.selectedID = shot.id
        }
        WindowRegistry.shared.present(self, dockIcon: true)
    }
}
