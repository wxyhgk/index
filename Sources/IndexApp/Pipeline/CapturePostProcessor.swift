import CoreGraphics
import Foundation

/// 截图元数据快照（后处理器需要的 shot 字段，不含图层/修订等重量数据）。
/// 由协调器在截图落库后构造一次，传给 pipeline，所有处理器共享。
struct ShotMetadata: Sendable {
    let title: String
    let sha256: String
    let appName: String?
    let capturedAt: Date
    let pixelWidth: Int
    let pixelHeight: Int
    let ocrText: String?

    init(
        title: String,
        sha256: String,
        appName: String?,
        capturedAt: Date,
        pixelWidth: Int,
        pixelHeight: Int,
        ocrText: String?
    ) {
        self.title = title
        self.sha256 = sha256
        self.appName = appName
        self.capturedAt = capturedAt
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.ocrText = ocrText
    }

    init(from shot: Shot) {
        self.init(
            title: shot.customTitle ?? shot.windowTitle ?? shot.appName ?? "截图",
            sha256: shot.sha256,
            appName: shot.appName,
            capturedAt: shot.capturedAt,
            pixelWidth: shot.pixelWidth,
            pixelHeight: shot.pixelHeight,
            ocrText: shot.ocrText
        )
    }

    /// 回填场景不需要元数据（补的是 attribute，不是 markdown），用空值占位。
    static let empty = ShotMetadata(
        title: "", sha256: "", appName: nil,
        capturedAt: Date.distantPast, pixelWidth: 0, pixelHeight: 0, ocrText: nil
    )
}

/// 一次后处理拿到的材料。刻意只给「原始像素 + 归因线索 + 元数据」——
/// 后处理器不该看到工具条动作、窗口、或任何 UI 概念。
struct PostProcessInput {
    let shotID: Int64
    /// 未标注的原始像素。
    let image: CGImage
    let appBundleID: String?
    /// 截图元数据快照（标题/尺寸/OCR 等）。
    let metadata: ShotMetadata
    /// 本次截图内共享的昂贵分析。生命周期不超过这一轮后处理。
    let analysis: PostProcessAnalysis

    init(
        shotID: Int64,
        image: CGImage,
        appBundleID: String?,
        metadata: ShotMetadata,
        analysis: PostProcessAnalysis? = nil
    ) {
        self.shotID = shotID
        self.image = image
        self.appBundleID = appBundleID
        self.metadata = metadata
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
    /// 写入结构化内容（Markdown/代码等）。
    func saveContent(shotID: Int64, kind: ContentKind, payload: ContentPayload) async
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
