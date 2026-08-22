import Foundation
import CoreGraphics
import GRDB

// MARK: - 图层几何 / 样式的可编码基元
// 全部使用「图像像素坐标系，原点左上角」。渲染器负责翻转。

struct LRect: Codable, Equatable {
    var x: Double
    var y: Double
    var w: Double
    var h: Double

    var cg: CGRect { CGRect(x: x, y: y, width: w, height: h).standardized }
    var start: CGPoint { CGPoint(x: x, y: y) }
    var end: CGPoint { CGPoint(x: x + w, y: y + h) }

    init(x: Double, y: Double, w: Double, h: Double) {
        self.x = x; self.y = y; self.w = w; self.h = h
    }

    init(_ r: CGRect) {
        self.init(x: r.origin.x, y: r.origin.y, w: r.width, h: r.height)
    }

    init(from a: CGPoint, to b: CGPoint) {
        self.init(x: a.x, y: a.y, w: b.x - a.x, h: b.y - a.y)
    }
}

struct LColor: Codable, Equatable {
    var r: Double
    var g: Double
    var b: Double
    var a: Double

    static let red = LColor(r: 0.98, g: 0.22, b: 0.22, a: 1)
    static let yellow = LColor(r: 1.0, g: 0.85, b: 0.15, a: 0.45)

    var cg: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
}

// MARK: - 图层

/// 一个标注图层。永远不写回原图，只作为 Revision 的一部分被序列化。
struct Layer: Codable, Identifiable, Equatable {
    enum Kind: String, Codable, CaseIterable {
        case rect
        case ellipse
        case arrow
        case line
        case text
        case highlight
        case pixelate
        case crop
        case counter
        case spotlight
        /// 测量：拖出矩形/线段，旁边标注图像像素尺寸。
        /// 标签文字在生成时按画布→像素倍率烤进 `text`（见 `AnnotationState`）。
        case dimension
        /// 美化：把成品垫在渐变/纯色背景上，内容圆角 + 投影 + 四周留白。
        /// 复用现有字段避免动 Codable：`lineWidth` = 留白 padding（像素）、
        /// `fontSize` = 内容圆角半径、`text` = 背景预设名、`color` = solid 预设的颜色。
        /// 同时只保留一层（见 `AnnotationState.toggleEffect`），只影响导出，不参与画布预览。
        case backdrop
        /// 水印：文字盖在成品上（白字 + 细黑描边，深浅底都可见），非破坏、进修订链。
        /// 复用现有字段避免动 Codable：`text` = `WatermarkSpec` 的 JSON
        /// （`{"mode":"corner","text":"@user"}`）、`color.a` = 透明度、
        /// `fontSize` = 字号（创建时按图宽 3% 烤入，min 14px）、
        /// `lineWidth` = 描边宽（创建时 = 1/pixelScale，投影后恰为 1 像素）。
        /// 同时只保留一层（见 `AnnotationState.toggleEffect`）；在裁剪之后、
        /// 美化之前套用，预览**会**画 —— 它影响构图判断，和 backdrop 不同。
        case watermark
        /// 外壳（带壳截图）：把内容套进 macOS 窗口壳 / 浏览器壳 ——
        /// 上方接标题栏（红绿灯 + 标题），浏览器壳再加一条地址栏，整体圆角裁剪。
        /// 复用现有字段避免动 Codable：`text` = 参数 JSON（见 `FrameSpec`：
        /// style / title / url）、`lineWidth` = 创建时烤入的像素倍率（壳的所有
        /// 结构尺寸按它缩放，Retina 下不发虚）。
        /// 同时只保留一层（见 `AnnotationState.toggleEffect`），只影响导出，不参与画布预览。
        case frame
        /// 捕获信息：成品底部接一条深色信息栏，排真实的捕获元数据 ——
        /// App 名+版本 / 来源网址 / 日期时间（竞品只能标 App 名+系统版本，网址是独家）。
        /// 复用现有字段避免动 Codable：`text` = 参数 JSON（见 `CaptureInfoSpec`：
        /// fields = 勾选要显示的字段，app/url/date = **开启效果时烤入**的真实值，
        /// 与 frame 的元数据填充同一时机、同一来源）、`lineWidth` = 创建时烤入的
        /// 像素倍率（信息栏的结构尺寸按它缩放，语义同 frame —— 「每视觉点的画布
        /// 单位」，投影乘 scale 后恰好是成品像素倍率，不会平方放大）。
        /// 同时只保留一层（见 `AnnotationState.toggleEffect`），只影响导出，不参与画布预览。
        case captureInfo

        /// 效果层：没有画布上的形体，只作用于导出成品的单例图层
        /// （水印 / 捕获信息 / 外壳 / 美化）。命中测试、缩放控制点、
        /// 矢量绘制、编辑器图层列表的排除全部由它派生 ——
        /// 新增效果 kind 只需在这里补一项，不再各处手维护黑名单。
        var isEffect: Bool {
            switch self {
            case .watermark, .captureInfo, .frame, .backdrop: return true
            default: return false
            }
        }

        var displayName: String {
            switch self {
            case .rect: return "矩形"
            case .ellipse: return "椭圆"
            case .arrow: return "箭头"
            case .line: return "直线"
            case .text: return "文字"
            case .highlight: return "高亮"
            case .pixelate: return "马赛克"
            case .crop: return "裁剪"
            case .counter: return "序号"
            case .spotlight: return "聚光灯"
            case .dimension: return "测量"
            case .backdrop: return "美化"
            case .watermark: return "水印"
            case .frame: return "外壳"
            case .captureInfo: return "捕获信息"
            }
        }

        var symbolName: String {
            switch self {
            case .rect: return "rectangle"
            case .ellipse: return "circle"
            case .arrow: return "arrow.up.right"
            case .line: return "line.diagonal"
            case .text: return "textformat"
            case .highlight: return "highlighter"
            case .pixelate: return "squareshape.split.3x3"
            case .crop: return "crop"
            case .counter: return "1.circle"
            case .spotlight: return "flashlight.on.fill"
            case .dimension: return "ruler"
            case .backdrop: return "sparkles.rectangle.stack"
            case .watermark: return "signature"
            case .frame: return "macwindow"
            case .captureInfo: return "info.square"
            }
        }
    }

    var id: UUID = UUID()
    var kind: Kind
    var rect: LRect
    var color: LColor = .red
    var lineWidth: Double = 4
    var text: String = ""
    var fontSize: Double = 28

    // —— 单工具参数（见 `ToolStyle`）。
    //
    // **必须是可选的**：Layer 的 Codable 是合成的，而合成的解码器**不会**使用默认值 ——
    // 加一个非可选字段会让所有旧修订的 JSON 直接解不出来。可选字段走 decodeIfPresent，
    // 旧数据解出 nil，渲染器据此退回硬编码默认值，行为与从前一模一样。

    /// 马赛克颗粒相对默认值的倍率。nil = 旧图层，用默认公式。
    var blockScale: Double?
    /// 聚光灯区域外的压暗程度（0…1）。nil = 旧图层，用 0.55。
    var dim: Double?
}

// MARK: - 截图记录（原图不可变）

struct Shot: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Equatable {
    static let databaseTableName = "shot"

    var id: Int64?
    /// 原图内容哈希，同时也是 originals/<sha256>.png 的文件名。
    var sha256: String
    var capturedAt: Date

    var pixelWidth: Int
    var pixelHeight: Int
    var scale: Double

    // —— 来源元数据（尽力采集，允许为空）
    var appName: String?
    var appBundleID: String?
    var appVersion: String?
    var appBuild: String?
    var windowTitle: String?
    /// 用户在图库里设置的显示名称。只改元数据，不重命名内容寻址原图。
    var customTitle: String? = nil
    var sourceURL: String?
    var displayID: Int?
    var displayName: String?

    /// 选区在全局屏幕坐标（AppKit，左下原点）中的位置，便于复现。
    var regionX: Double
    var regionY: Double
    var regionW: Double
    var regionH: Double

    /// Vision OCR 结果，异步回填，进 FTS5 索引。
    var ocrText: String?

    /// 原图文件扩展名（截图恒为 png；导入的 SVG 保留矢量文件为 svg）。
    var originalExtension: String? = "png"

    /// 卡片内容渲染分发类型（ContentKind rawValue）。默认 "image"。
    var contentKind: String = "image"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

extension Shot {
    static let customTitleMaxLength = 80

    var originalFileName: String { "\(sha256).\(originalExtension ?? "png")" }
    var thumbnailFileName: String { "\(sha256).jpg" }

    /// 图库名称与来源身份分离：用户名称最高，原文件名/窗口标题其次，App 只兜底。
    var primaryDisplayName: String {
        for candidate in [customTitle, windowTitle, appName] {
            let value = candidate?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let value, !value.isEmpty { return value }
        }
        return "未知来源"
    }

    static func normalizedCustomTitle(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(customTitleMaxLength))
    }

    /// 一行式来源描述，给列表用。
    var sourceSummary: String {
        var parts: [String] = []
        if let appName { parts.append(appVersion.map { "\(appName) \($0)" } ?? appName) }
        if let windowTitle, !windowTitle.isEmpty { parts.append(windowTitle) }
        return parts.isEmpty ? "未知来源" : parts.joined(separator: " — ")
    }
}

// MARK: - 修订（append-only，永不覆盖）

struct Revision: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Equatable {
    static let databaseTableName = "revision"

    var id: Int64?
    var shotID: Int64
    /// 指向上一版；nil 表示这是「原始」空图层版本。整棵历史构成一条链（将来可分叉）。
    var parentID: Int64?
    var createdAt: Date
    var note: String?
    /// [Layer] 的 JSON。
    var layersJSON: String

    enum Columns {
        static let shotID = Column("shotID")
        static let createdAt = Column("createdAt")
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

extension Revision {
    var layers: [Layer] {
        get {
            guard let data = layersJSON.data(using: .utf8) else { return [] }
            return (try? JSONDecoder().decode([Layer].self, from: data)) ?? []
        }
        set {
            let data = (try? JSONEncoder().encode(newValue)) ?? Data("[]".utf8)
            layersJSON = String(data: data, encoding: .utf8) ?? "[]"
        }
    }

    /// 数据库里存的一律是图像像素空间。
    var imageLayers: Layers<ImageSpace> { Layers(persisted: layers) }

    static func make(shotID: Int64, parentID: Int64?, layers: [Layer], note: String?) -> Revision {
        var r = Revision(
            id: nil,
            shotID: shotID,
            parentID: parentID,
            createdAt: Date(),
            note: note,
            layersJSON: "[]"
        )
        r.layers = layers
        return r
    }
}
