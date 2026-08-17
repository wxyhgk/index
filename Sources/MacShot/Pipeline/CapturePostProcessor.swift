import CoreGraphics

/// 一次后处理拿到的材料。刻意只给「原始像素 + 归因线索」——
/// 后处理器不该看到工具条动作、窗口、或任何 UI 概念。
struct PostProcessInput {
    let shotID: Int64
    /// 未标注的原始像素。
    let image: CGImage
    let appBundleID: String?
    /// 本次截图内共享的昂贵分析。生命周期不超过这一轮后处理。
    let analysis: PostProcessAnalysis

    init(
        shotID: Int64,
        image: CGImage,
        appBundleID: String?,
        analysis: PostProcessAnalysis? = nil
    ) {
        self.shotID = shotID
        self.image = image
        self.appBundleID = appBundleID
        self.analysis = analysis ?? PostProcessAnalysis(image: image)
    }
}

/// 派生属性的写入通道。
///
/// 后处理器只知道「往哪个 key 写什么值」，不知道有数据库、有列、有 FTS。
/// 此前 OCR 和浏览器地址各自硬编码调用 `ShotStore.shared.updateXXX`，
/// 这是同一段代码的两份拷贝 —— 抽象缺失的实证。
protocol ShotAttributeWriter: Sendable {
    func write(shotID: Int64, key: String, value: AttributeValue) async
}

/// 截图落库之后运行的派生处理。互相独立、可并发、失败不影响主流程。
///
/// 新增派生能力（CLIP 向量、自动打标签、水印、上传、通知）=
/// 新增一个实现 + 在 `BuiltinProcessors.registerAll` 里加一行。
/// **不需要**改 `CaptureCoordinator`，也**不需要**改数据库 schema。
protocol CapturePostProcessor {
    var id: String { get }
    /// 在主 actor 上求值 —— 通常是读设置开关。
    @MainActor var isEnabled: Bool { get }
    func process(_ input: PostProcessInput, writer: ShotAttributeWriter) async
}

extension CapturePostProcessor {
    @MainActor var isEnabled: Bool { true }
}
