import AppKit
import Combine
import SwiftUI

/// 标注编辑器的独立窗口 —— **单窗口模式**：全 App 同时只有一个编辑器窗口，
/// 再次双击别的截图不弹新窗，而是在这个窗口里换图（走和胶片条同一条
/// 未保存守卫链路）。编辑不再是模态 sheet，图库照常可用。
///
/// 生命周期由 `WindowRegistry.present(dockIcon: true, retain: true)` 统一持有
/// （同钉图的持有方式；编辑器是「正经窗口」，参与 Dock 图标引用计数）。
/// `current` 是弱引用 —— 强持有仍在 WindowRegistry 那一份，
/// 窗口关闭析构后自动置 nil，不构成第二套 living 集合。
@MainActor
final class EditorWindowController: NSWindowController {

    private static weak var current: EditorWindowController?

    private static let frameAutosaveName = "MacShotEditor"

    /// 当前编辑中的 shot。换图（`switchTo`）时更新。
    private var shot: Shot

    /// 图库双击 → 已有窗口时把换图请求发给视图（视图侧持有未保存基线，
    /// 守卫必须在那边跑）。视图 `.onReceive` 接住后走 `requestSwitch`。
    private let switchRequests = PassthroughSubject<Shot, Never>()

    /// 订阅库的变更：正在编辑的 shot 被删（图库删除等）时关掉本窗口 ——
    /// 编辑一条已不存在的记录没有意义，保存也无处可去。
    private var storeCancellable: AnyCancellable?

    /// 打开编辑器。已有窗口时不弹新窗：同一张就只激活，
    /// 不同张则把换图请求交给视图的未保存守卫。
    static func open(_ shot: Shot) {
        if let existing = current {
            NSApp.activate(ignoringOtherApps: true)
            existing.window?.makeKeyAndOrderFront(nil)
            if shot.id != existing.shot.id {
                existing.switchRequests.send(shot)
            }
            return
        }

        let controller = EditorWindowController(shot: shot)
        current = controller
        WindowRegistry.shared.present(controller, dockIcon: true, retain: true)
    }

    private init(shot: Shot) {
        self.shot = shot
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "标注 — \(shot.sourceSummary)"

        super.init(window: window)

        // 根视图在 super.init 之后再挂：回调闭包要捕获控制器
        // （换图回调必须打到 self，光捉窗口不够）。
        window.contentViewController = NSHostingController(rootView: makeRootView(for: shot))

        // 挂上内容后再定尺寸：NSHostingController 会把窗口缩到视图的理想尺寸。
        window.setContentSize(NSSize(width: 1000, height: 680))
        // 恢复上一次编辑器窗口的位置与大小；首次打开没有记录时居中。
        if !window.setFrameUsingName(Self.frameAutosaveName) {
            window.center()
        }
        window.setFrameAutosaveName(Self.frameAutosaveName)

        storeCancellable = ShotStore.shared.objectWillChange.sink { [weak self] _ in
            // objectWillChange 在变更**之前**发布；转一拍再查库，读到的才是变更后的状态。
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.closeIfShotDeleted() }
            }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - 换图（胶片条 / 图库双击共用）

    /// 不出编辑器换到另一张截图。
    ///
    /// 换图 = 重建 rootView：EditorView 保持 `shot: let` 零改动，重新走一遍
    /// onAppear → load()（`annotation.load` 清撤销栈，与打开新窗口行为一致）。
    /// 未保存守卫在 EditorView 侧（基线数据在视图内部），守卫通过后才会调到这里。
    func switchTo(_ target: Shot) {
        guard target.id != shot.id, let window else { return }

        shot = target
        window.title = "标注 — \(target.sourceSummary)"
        // 替换 contentViewController 会让窗口缩回视图的理想尺寸，先记住帧再恢复。
        let frame = window.frame
        window.contentViewController = NSHostingController(rootView: makeRootView(for: target))
        window.setFrame(frame, display: true)
    }

    private func makeRootView(for shot: Shot) -> EditorView {
        EditorView(
            shot: shot,
            onClose: { [weak self] in self?.window?.close() },
            onSwitchShot: { [weak self] target in self?.switchTo(target) },
            switchRequests: switchRequests.eraseToAnyPublisher()
        )
    }

    private func closeIfShotDeleted() {
        guard let id = shot.id, !ShotStore.shared.shotExists(id: id) else { return }
        window?.close()
    }
}
