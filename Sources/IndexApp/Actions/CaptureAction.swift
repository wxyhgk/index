import AppKit

/// 动作出现的场景。
enum ActionScope: Hashable {
    /// 截图选区确认后的工具条。
    case capture
    /// 钉图窗口上的工具条。
    case pinned
}

/// 同一宿主内的异步动作去重器。宿主各持有一份，避免一个钉图窗口连续点出
/// 多个上传 / 保存任务；不同钉图窗口之间互不阻塞。
struct ActionExecutionTracker {
    private(set) var executingIDs: Set<String> = []

    mutating func begin(_ id: String) -> Bool {
        executingIDs.insert(id).inserted
    }

    mutating func finish(_ id: String) {
        executingIDs.remove(id)
    }

    func isExecuting(_ id: String) -> Bool {
        executingIDs.contains(id)
    }
}

/// 动作执行时可以反过来要求宿主做的事。
/// 目前只有「关闭我自己」—— 钉图窗口的关闭按钮需要它。
@MainActor
protocol CaptureActionHost: AnyObject {
    func dismiss()
}

/// 一次动作执行拿到的全部材料。
///
/// 刻意携带**未合成的底图 + 图层**而不是成品位图：钉图窗口要靠它们继续
/// 非破坏性地画，而只想要成品的动作调一下 `rendered()` 即可。
@MainActor
struct CaptureContext {
    /// 未标注的原始像素。
    let base: CGImage
    let layers: Layers<ImageSpace>
    /// 已入库的记录。钉图窗口在极少数情况下可能没有（比如未来的临时预览）。
    let shot: Shot?
    /// 截图在屏幕上的位置，钉图用来钉回原位。钉图窗口内发起的动作没有这个概念。
    let region: CGRect?
    weak var host: CaptureActionHost?

    /// `CaptureContext` 是值类型，但一次截图会被自动副本、剪贴板、动作和 Shelf
    /// 分别复制。缓存放在引用盒里，让这些副本共享同一张成品，避免带标注的 4K 图
    /// 在同一轮主流程里被完整合成三四次。
    private let renderedArtifact = RenderedCaptureArtifact()

    init(
        base: CGImage,
        layers: Layers<ImageSpace>,
        shot: Shot?,
        region: CGRect?,
        host: CaptureActionHost?
    ) {
        self.base = base
        self.layers = layers
        self.shot = shot
        self.region = region
        self.host = host
    }

    /// 合成后的画面 —— 面向用户的产物几乎都要用它。
    func rendered() -> CGImage {
        renderedArtifact.resolve(base: base, layers: layers)
    }
}

/// 一次捕获会话内的惰性成品缓存。只经由 `@MainActor CaptureContext` 访问，
/// 不需要额外加锁；上下文销毁后缓存与成品像素一起释放。
@MainActor
private final class RenderedCaptureArtifact {
    private var image: CGImage?

    func resolve(base: CGImage, layers: Layers<ImageSpace>) -> CGImage {
        if let image { return image }
        let rendered = layers.isEmpty ? base : LayerRenderer.render(base: base, layers: layers)
        image = rendered
        return rendered
    }
}

/// 用户可以对一次截图执行的动作。
///
/// 新增动作 = 新增一个实现 + 在 `BuiltinActions.registerAll` 里加一行。
/// **不需要**改工具条、协调器、钉图窗口或任何 switch。
@MainActor
protocol CaptureAction {
    /// 稳定标识。会被持久化进快捷键设置，改名等于换了个动作。
    var id: String { get }
    var title: String { get }
    var symbolName: String { get }
    /// 在哪些工具条上出现。空集合表示只能由快捷键触发。
    var scopes: Set<ActionScope> { get }

    /// 这个动作自己决定剪贴板的去留，全局「自动复制」开关不要再叠加一次。
    ///
    /// 「复制」自己就会复制；「完成（不复制）」是用户明确要求不碰剪贴板 ——
    /// 此前这里是协调器里的一个 `default:` 分支，新动作会默认吃到自动复制，
    /// 「上传图床」会顺手覆盖剪贴板。
    var suppressesAutoCopy: Bool { get }

    /// 是否是主力动作。截图工具条平铺主力动作（钉图/录屏/长截图/复制/保存），
    /// 其余收进「更多」菜单（见 `MoreActionsControl`）。
    var isPrimaryAction: Bool { get }

    /// 允许长耗时、可失败。上传和生成 GIF 这类动作用同步 Void 根本表达不了。
    func perform(_ context: CaptureContext) async throws
}

extension CaptureAction {
    var suppressesAutoCopy: Bool { false }
    var isPrimaryAction: Bool { true }
}

/// 描述工具条上一个动作所需的最小信息。
/// 布局和绘制只认这个，不认动作实现本身 —— 也因此 `ToolbarItem` 还能保持 Equatable。
struct ToolbarActionDescriptor: Equatable {
    let id: String
    let title: String
    let symbolName: String
    /// 见 `CaptureAction.isPrimaryAction`：false 的在工具条上收进「更多」菜单。
    let isPrimary: Bool
}
