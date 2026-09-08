import CoreGraphics

// 平台能力契约。具体 macOS 实现按能力放在 Platform/macOS/。
// 这里只保留同时拥有生产实现和真实消费者的窄协议；不为假设中的移植场景
// 预留空协议。NSAlert、面板、剪贴板等系统副作用仍必须收口在 Platform/。

@MainActor
protocol ClipboardWriting {
    func copy(text: String)
    func copy(_ image: CGImage)
    func copy(_ images: [CGImage])
}

@MainActor
protocol ClipboardReading {
    func readText() -> String?
}

/// 屏幕捕获抽象：把 ScreenCaptureKit 等 macOS 专有调用
/// 隔离在 Platform/macOS/，调用方只依赖此协议。
@MainActor
protocol ScreenCapturing {
    var isPermissionGranted: Bool { get }
    @discardableResult
    func requestPermission() -> Bool
    /// 在同一份显示器拓扑上冻结全部活动显示器；不得返回部分成功结果。
    func captureDisplays() async throws -> [DisplaySnapshot]
    func captureWindow(windowID: CGWindowID, scale: CGFloat, includeShadow: Bool) async throws -> CGImage
}

/// 窗口列表抽象：把 CGWindowListCopyWindowInfo 隔离在 Platform/macOS/。
@MainActor
protocol WindowListing {
    func onScreenWindows(excludingPID pid: pid_t) -> [WindowInfo]
    func frontmostWindow(at point: CGPoint, excludingPID pid: pid_t) -> WindowInfo?
    func bestMatch(for region: CGRect, excludingPID pid: pid_t) -> WindowInfo?
}

/// 交互式分子钉图边界。调用方只传已经校验过的标准 XYZ 文本，不认识
/// WKWebView / NSPanel，也不承担窗口生命周期。
@MainActor
protocol MoleculePinning {
    func pinMolecule(xyz: String, atomCount: Int)
    /// 由 App 编排层注入“定格后如何落库并转为普通钉图”。平台窗口只负责
    /// 产生当前相机视角的像素，不反向依赖 Storage / Pin。
    func configureFreezeHandler(_ handler: @escaping MoleculeFreezeHandler)
}

struct MoleculeFreezeSnapshot {
    let image: CGImage
    /// 交互窗口内容区在全局 AppKit 坐标中的位置，普通钉图据此原地接替。
    let globalRegion: CGRect
    let scale: Double
}

typealias MoleculeFreezeHandler = @MainActor (
    MoleculeFreezeSnapshot,
    MoleculeSourceAttachment
) throws -> Void

extension MoleculePinning {
    /// 让简单替身继续只实现 `pinMolecule`；生产实现会保存此闭包。
    func configureFreezeHandler(_ handler: @escaping MoleculeFreezeHandler) {}
}

/// 进入鼠标穿透后的钉图收不到键盘事件，由统一注册表和菜单栏负责恢复。
@MainActor
protocol PinPassthroughControlling: AnyObject {
    func setPinPassthrough(_ enabled: Bool)
}
