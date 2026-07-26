import AppKit
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
        window.center()
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(selecting shot: Shot? = nil) {
        ShotStore.shared.reload()
        if let shot {
            GallerySelection.shared.selectedID = shot.id
        }
        WindowRegistry.shared.present(self, dockIcon: true)
    }
}
