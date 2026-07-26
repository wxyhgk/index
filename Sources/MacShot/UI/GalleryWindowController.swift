import AppKit
import SwiftUI

@MainActor
final class GalleryWindowController: NSWindowController {

    static let shared = GalleryWindowController()

    private init() {
        let hosting = NSHostingController(rootView: GalleryView())
        let window = NSWindow(contentViewController: hosting)
        window.title = "MacShot 图库"
        window.setContentSize(NSSize(width: 1080, height: 700))
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = false
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
