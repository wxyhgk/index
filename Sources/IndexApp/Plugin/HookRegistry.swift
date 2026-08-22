import CoreGraphics
import Foundation

// MARK: - Hook 事件系统（= Emacs hooks）
//
// 任何事件都能挂处理函数，插件挂 hook 就能响应，不改核心代码。
//
// 与 pipeline 的分工：
//   · pipeline = 截图后的重型派生（OCR/CLIP/特征指纹），有界并发、共享分析
//   · hook = 轻量扩展点（通知/日志/自定义），插件按需挂
//
// 后续阶段可以把 pipeline processor 也变成 hook handler，
// 但当前两者并存：pipeline 管"必须跑的重活"，hook 管"可选的扩展"。

// MARK: - 事件

enum HookEvent: Sendable {
    /// 截图落库后（= 当前 pipeline 的触发时机，但更轻量）。
    case afterCapture
    /// 删除前（可拦截：handler 返回 false 则取消删除）。
    case beforeDelete
    /// 打开编辑器/预览。
    case afterOpen
    /// 保存修订。
    case afterSave
    /// 剪贴板变化。
    case clipboardChanged
    /// 应用启动。
    case appLaunch
    /// 应用退出前。
    case appWillQuit
}

// MARK: - 上下文

/// hook 触发时传给 handler 的上下文。
struct HookContext: Sendable {
    let event: HookEvent
    let shotID: Int64?
    let image: CGImage?
    let metadata: ShotMetadata?
    let writer: (any ShotAttributeWriter)?
}

// MARK: - Handler

typealias HookHandler = @Sendable (HookContext) async -> Void

// MARK: - 注册表

@MainActor
final class HookRegistry: Sendable {

    static let shared = HookRegistry()

    private var handlers: [HookEvent: [HookHandler]] = [:]

    /// 挂一个 handler 到指定事件。
    func on(_ event: HookEvent, _ handler: @escaping HookHandler) {
        handlers[event, default: []].append(handler)
    }

    /// 摘掉某个事件的所有 handler。
    func clear(_ event: HookEvent) {
        handlers[event] = nil
    }

    /// 触发事件，并发执行所有 handler。
    func fire(_ event: HookEvent, context: HookContext) async {
        let list = handlers[event] ?? []
        guard !list.isEmpty else { return }
        await withTaskGroup(of: Void.self) { group in
            for handler in list {
                group.addTask { await handler(context) }
            }
        }
    }

    var registeredEvents: [HookEvent] { Array(handlers.keys) }
}
