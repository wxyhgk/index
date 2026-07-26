import AppKit
import UniformTypeIdentifiers

/// 存盘面板。此前 CaptureActionPerformer / EditorView / GalleryView 各写了一遍，
/// 且行为已经不一致 —— 只有一份带默认目录和 NSApp.activate。
@MainActor
enum ImageExporter {

    enum ExportError: LocalizedError {
        case encodingFailed
        var errorDescription: String? { "无法编码为 PNG" }
    }

    /// 弹面板让用户选位置。用户取消不算错误，返回 false。
    @discardableResult
    static func exportWithPanel(_ image: CGImage, suggestedName: String) throws -> Bool {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = suggestedName
        panel.directoryURL = FileManager.default
            .urls(for: .desktopDirectory, in: .userDomainMask).first

        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return false }

        guard let data = ImageCodec.pngData(from: image) else {
            throw ExportError.encodingFailed
        }
        try data.write(to: url)
        return true
    }

    /// 按用户模板渲染的建议文件名（含 .png 后缀）。
    /// 存盘面板、图库导出、自动副本全走这一个入口 —— 改模板处处生效。
    static func suggestedName(for shot: Shot?) -> String {
        renderName(
            template: AppSettings.shared.exportNameTemplate,
            date: shot?.capturedAt ?? Date(),
            appName: shot?.appName,
            windowTitle: shot?.windowTitle
        ) + ".png"
    }

    /// 模板渲染（不含扩展名）。变量：
    ///   {date}  yyyy-MM-dd
    ///   {time}  HH.mm.ss
    ///   {app}   带前导连字符的来源 App 名，没有则为空
    ///   {title} 窗口标题，截到 40 字符
    /// 替换完成后整体清洗一遍文件名非法字符 —— App 名和标题都可能带 `/`。
    /// 设置页的实时预览也调这里，渲染规则只有一份。
    nonisolated static func renderName(
        template: String,
        date: Date,
        appName: String?,
        windowTitle: String?
    ) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH.mm.ss"

        let title = String((windowTitle ?? "").prefix(40))
        let rendered = template
            .replacingOccurrences(of: "{date}", with: dateFormatter.string(from: date))
            .replacingOccurrences(of: "{time}", with: timeFormatter.string(from: date))
            .replacingOccurrences(of: "{app}", with: appName.map { "-\($0)" } ?? "")
            .replacingOccurrences(of: "{title}", with: title)

        let cleaned = sanitizedFileName(rendered)
        // 模板被清成空串（比如只写了个 "/"）也得有名字可用。
        return cleaned.isEmpty ? "截图" : cleaned
    }

    /// 去掉文件名非法字符：`/` 是路径分隔符、`:` 在访达里显示为 `/`，都换成连字符；
    /// 控制字符直接丢弃；开头的 `.` 会变成隐藏文件，一并去掉。
    nonisolated private static func sanitizedFileName(_ raw: String) -> String {
        var cleaned = ""
        cleaned.unicodeScalars.reserveCapacity(raw.unicodeScalars.count)
        for scalar in raw.unicodeScalars {
            if scalar == "/" || scalar == ":" {
                cleaned.unicodeScalars.append("-")
            } else if !CharacterSet.controlCharacters.contains(scalar) {
                cleaned.unicodeScalars.append(scalar)
            }
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespaces)
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        return cleaned
    }

    /// 无人值守地把已编码的 PNG 写进目录，重名自动加 -2 / -3 … 后缀。
    /// 「自动保存副本」在后台线程用，所以是 nonisolated。返回实际写入的位置。
    @discardableResult
    nonisolated static func writePNG(
        _ data: Data,
        into directory: URL,
        preferredName: String
    ) throws -> URL {
        let base = (preferredName as NSString).deletingPathExtension
        var ext = (preferredName as NSString).pathExtension
        if ext.isEmpty { ext = "png" }

        var candidate = directory.appendingPathComponent(preferredName)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base)-\(counter).\(ext)")
            counter += 1
        }
        // withoutOverwriting：探测和写入之间若有并发写入者抢先，报错而不是覆盖。
        try data.write(to: candidate, options: .withoutOverwriting)
        return candidate
    }
}
