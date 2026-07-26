import AppKit

/// 内置动作。
///
/// 这个文件是「新增动作」的唯一登记处 —— 加一个动作就是在下面写一个 struct，
/// 再往 `registerAll` 里加一行。工具条、协调器、钉图窗口都不需要改。

struct PinAction: CaptureAction {
    let id = ActionID.pin
    let title = "钉图"
    let symbolName = "pin.fill"
    let scopes: Set<ActionScope> = [.capture]

    func perform(_ context: CaptureContext) async throws {
        PinWindowController.pin(
            base: context.base,
            layers: context.layers,
            shot: context.shot,
            at: context.region ?? .zero
        )
    }
}

struct CopyAction: CaptureAction {
    let id = ActionID.copy
    let title = "复制"
    let symbolName = "doc.on.doc"
    let scopes: Set<ActionScope> = [.capture, .pinned]
    /// 自己就是复制，不需要全局自动复制再来一次。
    let suppressesAutoCopy = true

    func perform(_ context: CaptureContext) async throws {
        Clipboard.copy(context.rendered())
    }
}

struct SaveAction: CaptureAction {
    let id = ActionID.save
    let title = "保存"
    let symbolName = "square.and.arrow.down"
    let scopes: Set<ActionScope> = [.capture, .pinned]

    func perform(_ context: CaptureContext) async throws {
        try ImageExporter.exportWithPanel(
            context.rendered(),
            suggestedName: ImageExporter.suggestedName(for: context.shot)
        )
    }
}

struct CloseAction: CaptureAction {
    let id = ActionID.close
    let title = "关闭"
    let symbolName = "xmark"
    let scopes: Set<ActionScope> = [.pinned]

    func perform(_ context: CaptureContext) async throws {
        context.host?.dismiss()
    }
}

/// 只完成，不做别的。没有按钮，由回车在「完成（不复制）」设置下触发。
struct FinishAction: CaptureAction {
    let id = ActionID.finish
    let title = "完成"
    let symbolName = "checkmark"
    let scopes: Set<ActionScope> = []
    /// 用户明确选择了不碰剪贴板，必须压过全局自动复制开关。
    let suppressesAutoCopy = true

    func perform(_ context: CaptureContext) async throws {
        // 截图已经在协调器里入库了，这里确实什么都不用做。
    }
}

extension CaptureActionRegistry {
    /// 在这里登记。顺序即工具条上的显示顺序。
    static func registerBuiltins(into registry: CaptureActionRegistry) {
        registry.register(PinAction())
        registry.register(CopyAction())
        registry.register(SaveAction())
        registry.register(UploadAction())
        registry.register(CloseAction())
        registry.register(FinishAction())
    }
}
