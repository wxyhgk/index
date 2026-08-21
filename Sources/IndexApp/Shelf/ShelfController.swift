import AppKit

/// 快速暂存栏：截完图在屏幕右下角浮出的小卡片，直接拖出去就是 PNG 文件，
/// 不用先保存就能丢进聊天窗口或邮件。
///
/// 每张卡片是独立的 `ShelfCardController` 窗口；这里只负责编排 ——
/// 向上堆叠的位置、数量上限（超出挤掉最旧的）、拖拽临时文件目录的清理。
@MainActor
final class ShelfController {

    static let shared = ShelfController()

    /// 同时最多几张卡片，再多就挤掉最旧的。
    private static let maxCards = 3
    /// 离屏幕右下角的边距。
    private static let margin: CGFloat = 20
    /// 卡片之间的间距。
    private static let gap: CGFloat = 10

    /// 新的在前（屏幕最下方），旧的依次向上排。
    /// 强引用只用于排序 —— 生命周期仍由 WindowRegistry 持有，窗口关闭时这里同步摘除。
    private var cards: [ShelfCardController] = []
    private var observers: [ObjectIdentifier: NSObjectProtocol] = [:]

    private init() {}

    // MARK: - 展示

    func present(image: CGImage, shot: Shot?) {
        // 超出上限先挤掉最旧的（数组尾部）。close 会触发 willClose 回调同步摘除。
        while cards.count >= Self.maxCards, let oldest = cards.last {
            oldest.close()
        }

        // Shelf 窗口只有 240pt 宽，不需要把 4K/5K 成品在屏幕上强持有 15 秒。
        // 预览只留一个有界缩略图；真正拖出时再从图库的原图 + 最新修订重建成品。
        let preview = Self.makePreview(from: image)
        let fullImageProvider: @MainActor () -> CGImage?
        if let shot {
            // 这个分支刻意不捕获 `image`；否则闭包即使永远不走 fallback，
            // 仍会让全分辨率 backing 跟卡片活满 15 秒。
            fullImageProvider = {
                let store = ShotStore.shared
                guard let base = store.originalImage(for: shot) else { return nil }
                let layers = Layers<ImageSpace>(
                    persisted: store.latestRevision(for: shot)?.layers ?? []
                )
                return layers.isEmpty ? base : LayerRenderer.render(base: base, layers: layers)
            }
        } else {
            // 尚未入库的临时卡片没有可重建来源，只能保留原图。
            fullImageProvider = { image }
        }
        let card = ShelfCardController(
            previewImage: preview,
            shot: shot,
            fullImageProvider: fullImageProvider
        )
        cards.insert(card, at: 0)
        observeClose(of: card)

        // 先摆好位置再上屏：新卡片落在右下角，已有的向上让位。
        layout(animated: true)
        WindowRegistry.shared.present(card, dockIcon: false, retain: true)
        card.fadeIn()
    }

    /// Shelf 最多同时显示三张，按解码像素计也必须是常量级预算。
    /// 480px 足够覆盖 240pt Retina 卡片；缩放失败才退回原图。
    static func makePreview(from image: CGImage) -> CGImage {
        ImageCodec.resized(image, maxDimension: 480) ?? image
    }

    private func layout(animated: Bool) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        var y = visible.minY + Self.margin

        for card in cards {
            guard let window = card.window else { continue }
            let size = window.frame.size
            let frame = CGRect(
                x: visible.maxX - Self.margin - size.width,
                y: y,
                width: size.width,
                height: size.height
            )
            if animated, window.isVisible {
                window.animator().setFrame(frame, display: true)
            } else {
                window.setFrame(frame, display: true)
            }
            y = frame.maxY + Self.gap
        }
    }

    // MARK: - 生命周期

    private func observeClose(of card: ShelfCardController) {
        guard let window = card.window else { return }
        let key = ObjectIdentifier(window)
        observers[key] = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                ShelfController.shared.handleClose(windowKey: key)
            }
        }
    }

    private func handleClose(windowKey key: ObjectIdentifier) {
        if let observer = observers.removeValue(forKey: key) {
            NotificationCenter.default.removeObserver(observer)
        }
        cards.removeAll { card in
            card.window.map { ObjectIdentifier($0) == key } ?? true
        }
        // 剩下的卡片向下补位。
        layout(animated: true)
    }

    // MARK: - 拖拽临时文件

    /// 拖出去的 PNG 都写在这个目录下（每张卡一个子目录，避免同秒截图重名）。
    static var dragFileDirectory: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("IndexShelfDrag", isDirectory: true)
    }

    /// 启动时清掉上次会话留下的拖拽临时文件。
    /// 不能在拖出后立刻删 —— 接收方（Slack、邮件）可能还在异步读那个文件。
    static func cleanupDragFiles() {
        let dir = dragFileDirectory
        Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: dir)
        }
    }
}
