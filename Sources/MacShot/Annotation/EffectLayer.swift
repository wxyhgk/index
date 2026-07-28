import Foundation
import CoreGraphics

// MARK: - 效果层契约
//
// 「效果层」= 没有画布形体、只作用于导出成品的单例图层：
// 水印 / 捕获信息 / 外壳 / 美化（`Layer.Kind.isEffect`）。
// 这里定义它们的统一契约：
//   · `EffectContext`   —— 开启效果那一刻要烤入参数的全部注入值（一个值对象，
//     取代此前散在 `AnnotationState` 上的 6 个注入属性）
//   · `EffectDescriptor` —— 一个效果 = kind + 导出次序 + 造层函数 + 预览画法
//   · `EffectRegistry`  —— 有序注册表。新增效果 = 加一个描述符，
//     开关（`AnnotationState.toggleEffect`）、工具条控件（`EffectToggleControl`）、
//     导出编排（`LayerRenderer.render`）、预览（`AnnotationRenderer`）都不用改。

/// 开启效果那一刻的注入上下文。三宿主在构造/装载时各设一次
/// `AnnotationState.effectContext` 闭包，值在开关那一刻现取（烤入语义）：
///   · 覆盖层：选区宽、窗口归因都以开关瞬间为准（URL 是落库后异步回填的 → 留空）
///   · 钉图 / 编辑器：shot 落库的真实归因
struct EffectContext {
    /// 成品图**像素宽**，水印字号按「图宽 3%」烤入时用。0 = 未知，只按 14px 下限走。
    var imagePixelWidth: Double = 0

    /// 画布单位到图像像素的倍率。由 `AnnotationState.toggleEffect` 从自身的
    /// `pixelScale` 补进来，宿主不用设 —— 水印的字号/描边按它反除到画布单位。
    var pixelScale: Double = 1

    /// 壳 / 信息栏结构尺寸的倍率，语义是「每**视觉点**对应多少画布单位」，
    /// 投影到图像像素时随 scale 一起放大：
    ///   · 覆盖层画布是显示器的点 —— 保持 1，投影乘 snapshot.scale 后正好是 Retina 倍率
    ///   · 编辑器/钉图画布已是图像像素（投影恒等）—— 设 shot.scale，
    ///     2x 图上的壳和 1x 图视觉大小一致，线条落在整像素上不发虚
    var chromeScale: Double = 1

    /// 真实元数据（尽力采集，允许为空）。竞品的带壳都是空壳 ——
    /// 「标题栏是真实窗口标题、地址栏是真实网址」是元数据库独有的卖点。
    var windowTitle: String?
    var sourceURL: String?
    /// 「App 名 + 版本」一行式描述（`CaptureInfoSpec.appDescription`）。
    var appDescription: String?
    /// 捕获时刻。nil = 当下（覆盖层：截图那一刻就是现在）。
    var capturedAt: Date?
}

/// 一个效果的完整描述。
struct EffectDescriptor {
    let kind: Layer.Kind

    /// 导出时在裁剪之后的应用次序（小的先套）。`LayerRenderer.render`
    /// 按注册表这份次序编排：水印 → 捕获信息 → 外壳 → 美化。
    let renderOrder: Int

    /// 造一层画布空间的效果层，参数在此刻烤入 `Layer.text`。
    /// 读 AppSettings 的（水印文案/模式/透明度）也收敛在这里 ——
    /// 工具条、编辑器面板、自动水印共用同一份默认值逻辑。
    let makeLayer: @MainActor (EffectContext) -> Layer

    /// 实时预览的画法；nil = 不参与预览（画布尺寸不随开关变，
    /// 工具条高亮已足够表达状态）。目前只有水印参与 —— 它盖在画面上，
    /// 影响构图判断。参数：(图层, 上下文, 成品范围)，上下文须已是左上原点。
    let previewDraw: ((Layer, CGContext, CGRect) -> Void)?

    /// 是否画进实时预览（`previewDraw` 的有无）。
    var participatesInPreview: Bool { previewDraw != nil }
}

/// 效果的有序注册表。四个内置效果各登记一个描述符；
/// `ordered` 的次序就是导出时的套用次序。
enum EffectRegistry {

    /// 信息栏日期的固定排版（本地时区）。烤入后是纯文本，历史成品不随时区漂移。
    @MainActor private static let captureInfoDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    /// 水印：字号按成品图宽 3%（不小于 14px）烤成图像像素，再反除 `pixelScale`
    /// 换到画布单位；描边同理（1 像素 → 1/pixelScale 画布单位）。
    /// 投影（×pixelScale）后恰好回到烤定的像素值 —— 预览画的和导出画的
    /// 因此是同一个大小，思路与测量标注把数值烤进 `text` 一致。
    /// 设置没配文案时用 `WatermarkSpec.defaultText` 兜底 —— 开关必须永远可用。
    static let watermark = EffectDescriptor(
        kind: .watermark,
        renderOrder: 0,
        makeLayer: { context in
            let settings = AppSettings.shared
            let text = settings.trimmedWatermarkText
            var layer = WatermarkSpec.makeLayer(
                text: text.isEmpty ? WatermarkSpec.defaultText : text,
                mode: settings.watermarkMode,
                alpha: settings.watermarkAlpha,
                imagePixelWidth: context.imagePixelWidth
            )
            layer.fontSize /= context.pixelScale
            layer.lineWidth /= context.pixelScale
            return layer
        },
        previewDraw: { layer, ctx, canvas in
            LayerRenderer.drawWatermark(layer, in: ctx, canvas: canvas)
        }
    )

    /// 捕获信息：元数据（App 名+版本 / 网址 / 日期）在开启这一刻烤进参数
    /// JSON —— 之后图层自带数据，导出不再回查。
    static let captureInfo = EffectDescriptor(
        kind: .captureInfo,
        renderOrder: 1,
        makeLayer: { context in
            var layer = Layer(kind: .captureInfo, rect: LRect(x: 0, y: 0, w: 0, h: 0))
            layer.lineWidth = context.chromeScale   // 复用字段：信息栏结构尺寸倍率
            var spec = CaptureInfoSpec()
            spec.app = context.appDescription ?? ""
            spec.url = context.sourceURL ?? ""
            spec.date = captureInfoDateFormatter.string(from: context.capturedAt ?? Date())
            layer.text = spec.json
            return layer
        },
        previewDraw: nil
    )

    /// 外壳（带壳截图）：默认 macos 壳，标题/网址从注入的元数据自动填。
    static let frame = EffectDescriptor(
        kind: .frame,
        renderOrder: 2,
        makeLayer: { context in
            var layer = Layer(kind: .frame, rect: LRect(x: 0, y: 0, w: 0, h: 0))
            layer.lineWidth = context.chromeScale   // 复用字段：壳的结构尺寸倍率
            var spec = FrameSpec()
            spec.title = context.windowTitle ?? ""
            spec.url = context.sourceURL ?? ""
            layer.text = spec.json
            return layer
        },
        previewDraw: nil
    )

    /// 美化：默认预设 + 固定留白/圆角。
    static let backdrop = EffectDescriptor(
        kind: .backdrop,
        renderOrder: 3,
        makeLayer: { _ in
            var layer = Layer(kind: .backdrop, rect: LRect(x: 0, y: 0, w: 0, h: 0))
            layer.lineWidth = 48            // 复用字段：四周留白 padding
            layer.fontSize = 12             // 复用字段：内容圆角半径
            layer.text = BackdropPreset.default.rawValue
            return layer
        },
        previewDraw: nil
    )

    /// 全部效果，按导出套用次序排好（`renderOrder` 升序）。
    static let ordered: [EffectDescriptor] =
        [watermark, captureInfo, frame, backdrop]
            .sorted { $0.renderOrder < $1.renderOrder }

    static func descriptor(for kind: Layer.Kind) -> EffectDescriptor? {
        ordered.first { $0.kind == kind }
    }
}
