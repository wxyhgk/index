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
    /// 钉图窗口要读的设置切片（回车语义 / 标注样式持久化）。
    private let capture: any CapturePreferences
    private let annotationStyle: any AnnotationStylePreferences

    init(capture: any CapturePreferences, annotationStyle: any AnnotationStylePreferences) {
        self.capture = capture
        self.annotationStyle = annotationStyle
    }

    func perform(_ context: CaptureContext) async throws {
        PinWindowController.pin(
            base: context.base,
            layers: context.layers,
            shot: context.shot,
            at: context.region ?? .zero,
            capture: capture,
            annotationStyle: annotationStyle
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
        // 走 sheet 那条路：面板落在刚才截图的那块屏上，而且不必激活整个 App ——
        // 后者会把图库那组 stage 一起拽到前台，把用户正在用的软件挤进侧边条。
        // 钉图窗口发起时 region 为 nil，退回 key 窗口 / 指针那块屏。
        try await ImageExporter.exportWithPanel(
            context.rendered(),
            suggestedName: ImageExporter.suggestedName(for: context.shot),
            over: context.region
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

struct RecordAction: CaptureAction {
    let id = ActionID.record
    let title = "录屏"
    let symbolName = "video"
    let scopes: Set<ActionScope> = [.capture]
    let suppressesAutoCopy = true

    func perform(_ context: CaptureContext) async throws {
        // 截图工具条上直接进录屏：不入库当前选区，避免多一张无用截图
        // 真正的选区由 RecordingCoordinator 的 plain 覆盖层重新框选
        await MainActor.run { RecordingCoordinator.shared.toggle() }
    }
}

struct ScrollCaptureAction: CaptureAction {
    let id = ActionID.scrollCapture
    let title = "长截图"
    let symbolName = "arrow.down.doc"
    let scopes: Set<ActionScope> = [.capture]
    let suppressesAutoCopy = true

    func perform(_ context: CaptureContext) async throws {
        await MainActor.run { ScrollCaptureController.shared.begin() }
    }
}

extension CaptureActionRegistry {
    /// 在这里登记。顺序即工具条上的显示顺序。
    /// 注入式：装配根（AppDelegate）传全量设置，预览/测试传 `FakeStyleStore`。
    static func registerBuiltins(
        into registry: CaptureActionRegistry,
        styleStore: any StyleStore
    ) {
        registry.register(PinAction(capture: styleStore, annotationStyle: styleStore))
        registry.register(RecordAction())
        registry.register(ScrollCaptureAction())
        registry.register(CopyAction())
        registry.register(SaveAction())
        registry.register(CopyTextAction())
        registry.register(BugReportAction())
        registry.register(UploadAction(upload: styleStore))
        registry.register(CloseAction())
        registry.register(FinishAction())
    }
}
