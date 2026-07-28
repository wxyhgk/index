import Foundation
import CoreGraphics

// MARK: - 效果层的参数模型
//
// 四个效果层（backdrop / watermark / frame / captureInfo）把参数序列化进
// `Layer.text`，复用现有字段、不动 Layer 的 Codable —— 这些类型就是那份
// 序列化格式的定义，和 `Layer` 同层（值类型、不 import AppKit）。
// 绘制实现在 `LayerRenderer`，开关编排在 `AnnotationState.toggleEffect`，
// 描述符注册表在 `EffectLayer.swift`。

/// 美化层（backdrop）的背景预设。`Layer.text` 存 rawValue。
enum BackdropPreset: String, CaseIterable {
    case gradientBlue = "gradient-blue"
    case gradientSunset = "gradient-sunset"
    case gradientMono = "gradient-mono"
    case solid = "solid"

    static let `default`: BackdropPreset = .gradientBlue

    var displayName: String {
        switch self {
        case .gradientBlue: return "蓝紫渐变"
        case .gradientSunset: return "日落渐变"
        case .gradientMono: return "灰黑渐变"
        case .solid: return "纯色"
        }
    }

    /// 渐变两端的颜色；solid 返回 nil（用图层自身的 `color`）。
    var gradientColors: (CGColor, CGColor)? {
        switch self {
        case .gradientBlue:
            return (
                CGColor(srgbRed: 0.31, green: 0.46, blue: 0.98, alpha: 1),
                CGColor(srgbRed: 0.55, green: 0.29, blue: 0.94, alpha: 1)
            )
        case .gradientSunset:
            return (
                CGColor(srgbRed: 0.99, green: 0.56, blue: 0.30, alpha: 1),
                CGColor(srgbRed: 0.94, green: 0.31, blue: 0.60, alpha: 1)
            )
        case .gradientMono:
            return (
                CGColor(srgbRed: 0.24, green: 0.25, blue: 0.28, alpha: 1),
                CGColor(srgbRed: 0.08, green: 0.08, blue: 0.10, alpha: 1)
            )
        case .solid:
            return nil
        }
    }
}

/// 水印的摆放模式。`WatermarkSpec.mode` 存 rawValue。
enum WatermarkMode: String, Codable, CaseIterable, Identifiable {
    /// 右下角一行，边距 = 字号。
    case corner
    /// 居中斜排，字号 ×1.6。
    case center
    /// 斜向平铺，盖满全图。
    case tile

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .corner: return "右下角"
        case .center: return "居中"
        case .tile: return "平铺"
        }
    }
}

/// 水印层的参数。整体序列化成 JSON 存进 `Layer.text`：
/// `{"mode":"corner","text":"@user"}` —— 复用现有字段，不动 Codable。
struct WatermarkSpec: Codable, Equatable {
    var text: String
    var mode: WatermarkMode

    /// 设置里没配文案时的兜底 —— 开关必须永远可用。
    /// 唯一的一份：工具条开关、编辑器效果面板、自动水印全部经
    /// 描述符 `EffectRegistry` 的 makeLayer 用到它。
    static let defaultText = "MacShot"

    /// 存进 `Layer.text` 的 JSON。键排序固定，同参数编码结果一致（Layer 是 Equatable）。
    var encoded: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func decode(_ json: String) -> WatermarkSpec? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(WatermarkSpec.self, from: data)
    }

    /// 造一层**图像像素空间**的水印层：字号 = 图宽 3%（不小于 14px）、描边 1 像素、
    /// 白字（透明度 = `alpha`）。画布空间创建时由描述符（`EffectRegistry`）
    /// 把 fontSize / lineWidth 反除 pixelScale 换到画布单位。
    static func makeLayer(
        text: String, mode: WatermarkMode, alpha: Double, imagePixelWidth: Double
    ) -> Layer {
        var layer = Layer(kind: .watermark, rect: LRect(x: 0, y: 0, w: 0, h: 0))
        layer.text = WatermarkSpec(text: text, mode: mode).encoded
        layer.color = LColor(r: 1, g: 1, b: 1, a: alpha)
        layer.fontSize = max(14, imagePixelWidth * 0.03)
        layer.lineWidth = 1
        return layer
    }
}

/// 外壳层（frame）的参数。`Layer.text` 存 JSON：
/// `{"style":"macos"|"browser","title":"…","url":"…"}`。
/// backdrop 只有一个预设名所以存 rawValue 字符串就够；壳有三个字段，用 JSON。
/// 字段全部可缺省，逐字段容错：解析失败退回 macos 空壳，老数据/坏数据都不至于炸。
struct FrameSpec: Codable, Equatable {
    enum Style: String, Codable, CaseIterable {
        case macos
        case browser

        var displayName: String {
            switch self {
            case .macos: return "macOS 窗口"
            case .browser: return "浏览器"
            }
        }
    }

    var style: Style = .macos
    var title: String = ""
    var url: String = ""

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        style = (try? container.decode(Style.self, forKey: .style)) ?? .macos
        title = (try? container.decode(String.self, forKey: .title)) ?? ""
        url = (try? container.decode(String.self, forKey: .url)) ?? ""
    }

    /// 解析 `Layer.text`。任何失败（空串、坏 JSON、未知 style）都退回 macos 空壳。
    static func parse(_ json: String) -> FrameSpec {
        guard let data = json.data(using: .utf8),
              let spec = try? JSONDecoder().decode(FrameSpec.self, from: data)
        else { return FrameSpec() }
        return spec
    }

    var json: String {
        guard let data = try? JSONEncoder().encode(self),
              let string = String(data: data, encoding: .utf8)
        else { return "{}" }
        return string
    }
}

/// 捕获信息层（captureInfo）的参数。`Layer.text` 存 JSON：
/// `{"fields":["app","url","date"],"app":"Safari 17.4","url":"https://…","date":"2026-07-27 14:30"}`。
/// `fields` 是用户勾选要显示的字段；具体值在**开启效果时烤入**（编辑器/钉图从
/// shot 取，覆盖层从 confirmedWindow 取、URL 留空）—— 和 frame 的元数据填充
/// 同一时机、同一来源。照 `FrameSpec` 的模式逐字段容错：解析失败退回全勾空值，
/// 老数据/坏数据都不至于炸；`fields` 里出现未来版本的未知字段名时逐个丢弃。
struct CaptureInfoSpec: Codable, Equatable {
    enum Field: String, Codable, CaseIterable {
        case app
        case url
        case date

        var displayName: String {
            switch self {
            case .app: return "App"
            case .url: return "网址"
            case .date: return "时间"
            }
        }
    }

    var fields: [Field] = Field.allCases
    var app: String = ""
    var url: String = ""
    var date: String = ""

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // fields 按裸字符串解，未知字段名逐个丢弃而不是让整个数组失败。
        if let raw = try? container.decode([String].self, forKey: .fields) {
            fields = raw.compactMap(Field.init(rawValue:))
        }
        app = (try? container.decode(String.self, forKey: .app)) ?? ""
        url = (try? container.decode(String.self, forKey: .url)) ?? ""
        date = (try? container.decode(String.self, forKey: .date)) ?? ""
    }

    /// 解析 `Layer.text`。任何失败（空串、坏 JSON）都退回全勾空值的缺省参数。
    static func parse(_ json: String) -> CaptureInfoSpec {
        guard let data = json.data(using: .utf8),
              let spec = try? JSONDecoder().decode(CaptureInfoSpec.self, from: data)
        else { return CaptureInfoSpec() }
        return spec
    }

    /// 键排序固定，同参数编码结果一致（Layer 是 Equatable，style 撤销记录靠它判等）。
    var json: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self),
              let string = String(data: data, encoding: .utf8)
        else { return "{}" }
        return string
    }

    /// 「App 名 + 版本」的一行式描述（如 "Safari 17.4"）。三处注入点共用，
    /// 保证同一份元数据在哪儿开效果都排出同样的字。
    static func appDescription(name: String?, version: String?) -> String? {
        guard let name, !name.isEmpty else { return nil }
        guard let version, !version.isEmpty else { return name }
        return "\(name) \(version)"
    }
}
