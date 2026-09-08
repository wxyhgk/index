import Foundation

// MARK: - Agent 的 set_config 后端
//
// 把 LLM 给的 key/value 真正写进 AppSettings（走 @Published didSet 自动落盘）。
// key 是白名单里的人类可读名（给 LLM 看），value 是字符串，按目标类型解析。
//
// 用 WritableKeyPath 映射表驱动：加一个可改项 = 往对应字典加一行，
// 不用写新的 switch 分支。写入经过中间 @Published 属性的 setter，didSet 自动持久化。
@MainActor
enum ConfigSetter {

    // 布尔项：key → (写入路径, 中文名)
    private static let bools: [String: (path: WritableKeyPath<AppSettings, Bool>, label: String)] = [
        "capture.copyToClipboard": (\.capture.copyToClipboard, "复制到剪贴板"),
        "capture.showShelfCard": (\.capture.showShelfCard, "暂存卡片"),
        "capture.showMagnifier": (\.capture.showMagnifier, "放大镜"),
        "capture.windowCaptureShadow": (\.capture.windowCaptureShadow, "整窗阴影"),
        "recording.recordSystemAudio": (\.recording.recordSystemAudio, "录屏系统声音"),
        "recording.recordMicrophone": (\.recording.recordMicrophone, "录屏麦克风"),
        "recording.recordingSaveToLibrary": (\.recording.recordingSaveToLibrary, "录屏保存到图库"),
        "export.autoCopyEnabled": (\.export.autoCopyEnabled, "自动副本"),
        "library.autoCleanupEnabled": (\.library.autoCleanupEnabled, "自动清理"),
        "library.galleryScrollDepth": (\.library.galleryScrollDepth, "滚动深度效果"),
        "annotation.autoWatermark": (\.annotationStyle.autoWatermark, "自动加水印"),
        "annotation.autoBackdrop": (\.annotationStyle.autoBackdrop, "自动美化"),
        "intelligence.runOCR": (\.intelligence.runOCR, "OCR 文字识别"),
        "intelligence.autoClassify": (\.intelligence.autoClassify, "自动分类"),
        "intelligence.detectSensitive": (\.intelligence.detectSensitive, "敏感内容检测"),
        "intelligence.semanticSearch": (\.intelligence.semanticSearch, "语义搜索"),
        "clipboardHistory.enabled": (\.clipboardHistory.enabled, "剪贴板历史"),
    ]

    // 整数项
    private static let ints: [String: (path: WritableKeyPath<AppSettings, Int>, label: String)] = [
        "capture.captureDelay": (\.capture.captureDelay, "截图延时（秒）"),
        "library.autoCleanupDays": (\.library.autoCleanupDays, "自动清理保留天数"),
        "clipboardHistory.retentionDays": (\.clipboardHistory.retentionDays, "剪贴板历史保留天数"),
    ]

    // 字符串项
    private static let strings: [String: (path: WritableKeyPath<AppSettings, String>, label: String)] = [
        "export.exportNameTemplate": (\.export.exportNameTemplate, "文件名模板"),
        "annotation.watermarkText": (\.annotationStyle.watermarkText, "水印文案"),
    ]

    /// 所有可改的配置项名（list_config_keys 工具用）。
    static var availableKeys: [String] {
        (Array(bools.keys) + Array(ints.keys) + Array(strings.keys) + ["capture.enterBehavior"]).sorted()
    }

    /// 应用一个配置变更，返回给 LLM 的结果文本。
    static func apply(key: String, value: String) -> String {
        var settings = AppSettings.shared
        let key = key.trimmingCharacters(in: .whitespaces)
        let value = value.trimmingCharacters(in: .whitespaces)

        if let (path, label) = bools[key] {
            guard let v = parseBool(value) else { return "「\(value)」不是布尔值（用 true/false/开/关）" }
            settings[keyPath: path] = v
            return "已把「\(label)」设为 \(v ? "开" : "关")"
        }
        if let (path, label) = ints[key] {
            guard let v = Int(value) else { return "「\(value)」不是数字" }
            settings[keyPath: path] = v
            return "已把「\(label)」设为 \(v)"
        }
        if let (path, label) = strings[key] {
            settings[keyPath: path] = value
            return "已把「\(label)」设为「\(value)」"
        }
        if key == "capture.enterBehavior" {
            guard let behavior = AppSettings.EnterBehavior(rawValue: value) else {
                return "「\(value)」不是回车行为（用 copyAndFinish/finishOnly）"
            }
            settings.capture.enterBehavior = behavior
            return "已把「回车行为」设为 \(behavior.title)"
        }
        return "未知配置项「\(key)」。可用项：\(availableKeys.joined(separator: "、"))"
    }

    /// 宽松布尔解析：接受 true/false、1/0、开/关、on/off、yes/no。
    static func parseBool(_ s: String) -> Bool? {
        switch s.lowercased() {
        case "true", "1", "开", "on", "yes", "y": return true
        case "false", "0", "关", "off", "no", "n": return false
        default: return nil
        }
    }
}
