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
        /// 同时只保留一层（见 `AnnotationState.toggleBackdrop`），只影响导出，不参与画布预览。
        case backdrop
        /// 外壳（带壳截图）：把内容套进 macOS 窗口壳 / 浏览器壳 ——
        /// 上方接标题栏（红绿灯 + 标题），浏览器壳再加一条地址栏，整体圆角裁剪。
        /// 复用现有字段避免动 Codable：`text` = 参数 JSON（见 `FrameSpec`：
        /// style / title / url）、`lineWidth` = 创建时烤入的像素倍率（壳的所有
        /// 结构尺寸按它缩放，Retina 下不发虚）。
        /// 同时只保留一层（见 `AnnotationState.toggleFrame`），只影响导出，不参与画布预览。
        case frame

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
            case .frame: return "外壳"
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
            case .frame: return "macwindow"
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

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

extension Shot {
    var originalFileName: String { "\(sha256).png" }
    var thumbnailFileName: String { "\(sha256).jpg" }

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
