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

    static func suggestedName(for shot: Shot?) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        guard let shot else {
            return "截图 \(formatter.string(from: Date())).png"
        }
        let app = shot.appName.map { "-\($0)" } ?? ""
        return "截图 \(formatter.string(from: shot.capturedAt))\(app).png"
    }
}
