import AppKit
import Combine
import SwiftUI

/// 标注编辑器的独立窗口。每个 shot 一个窗口实例 —— 编辑不再是模态 sheet，
/// 图库照常可用，多张截图可以并排同时编辑、互相参考。
///
/// 生命周期由 `WindowRegistry.present(dockIcon: true, retain: true)` 统一持有
/// （同钉图的持有方式；编辑器是「正经窗口」，参与 Dock 图标引用计数）。
/// 查重是本控制器自己的弱引用映射：WindowRegistry 只管生命周期不做查重，
/// 同一张图重复打开时激活已有窗口而不是再开一个。
@MainActor
final class EditorWindowController: NSWindowController {

    /// shotID → 已打开的编辑器窗口。**弱引用** —— 强持有仍在 WindowRegistry
    /// （retain: true）那一份，这里只做查重，窗口析构后自动出表，
    /// 不构成第二套 living 集合。
    private static let openEditors =
        NSMapTable<NSNumber, EditorWindowController>.strongToWeakObjects()

    /// 所有编辑器窗口共用一个 frame autosave 名：用户预期是
    /// 「编辑器上次的位置和大小」，按 shot 独立记没有必要。
    private static let frameAutosaveName = "MacShotEditor"

    /// 当前编辑中的 shot。胶片条换图（`switchTo`）时更新，查重表随之迁移。
    private var shot: Shot

    /// 订阅库的变更：正在编辑的 shot 被删（图库删除等）时关掉本窗口 ——
    /// 编辑一条已不存在的记录没有意义，保存也无处可去。
    private var storeCancellable: AnyCancellable?

    /// 打开（或激活）某张截图的编辑器窗口。
    static func open(_ shot: Shot) {
        if let id = shot.id,
           let existing = openEditors.object(forKey: NSNumber(value: id)) {
            NSApp.activate(ignoringOtherApps: true)
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }

        let controller = EditorWindowController(shot: shot)
        if let id = shot.id {
            openEditors.setObject(controller, forKey: NSNumber(value: id))
        }
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
        // 同名 autosave 同时只能挂在一个窗口上：第二个编辑器挂不上（返回 false）,
        // 只恢复不追踪，并往右下错开一点，避免和已有窗口完全重叠。
        if !window.setFrameAutosaveName(Self.frameAutosaveName) {
            window.setFrameTopLeftPoint(
                NSPoint(x: window.frame.minX + 28, y: window.frame.maxY - 28)
            )
        }

        storeCancellable = ShotStore.shared.objectWillChange.sink { [weak self] _ in
            // objectWillChange 在变更**之前**发布；转一拍再查库，读到的才是变更后的状态。
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.closeIfShotDeleted() }
            }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - 换图（胶片条驱动）

    /// 不出编辑器换到另一张截图。
    ///
    /// 换图 = 重建 rootView：EditorView 保持 `shot: let` 零改动，重新走一遍
    /// onAppear → load()（`annotation.load` 清撤销栈，与打开新窗口行为一致）。
    /// 未保存守卫在 EditorView 侧（基线数据在视图内部），守卫通过后才会调到这里。
    ///
    /// 目标 shot 已有另一个编辑器窗口时**不换图**，转而激活那个窗口 ——
    /// 与 `open(_:)` 的查重语义一致；否则查重表迁移：旧 shotID 出表、新 shotID 入表。
    func switchTo(_ target: Shot) {
        guard target.id != shot.id, let window else { return }

        if let id = target.id,
           let existing = Self.openEditors.object(forKey: NSNumber(value: id)),
           existing !== self {
            NSApp.activate(ignoringOtherApps: true)
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }

        if let oldID = shot.id {
            Self.openEditors.removeObject(forKey: NSNumber(value: oldID))
        }
        shot = target
        if let newID = target.id {
            Self.openEditors.setObject(self, forKey: NSNumber(value: newID))
        }

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
            onSwitchShot: { [weak self] target in self?.switchTo(target) }
        )
    }

    private func closeIfShotDeleted() {
        guard let id = shot.id, !ShotStore.shared.shotExists(id: id) else { return }
        window?.close()
    }
}
