import AppKit

/// 执行工具条上的动作。
/// 单独拆出来是因为这一层是**副作用的集散地** —— 钉图窗口、剪贴板、存盘面板、编辑器窗口，
/// 每一个都是不同的子系统。混在截图流程里会让流程本身无法阅读。
@MainActor
enum CaptureActionPerformer {

    static func perform(_ action: CaptureAction, image: CGImage, shot: Shot, region: CGRect) {
        switch action {
        case .pin:
            PinWindowController.pin(image: image, shot: shot, at: region)

        case .copy:
            ImageCodec.copyToPasteboard(image)

        case .annotate:
            EditorWindowController.open(shot: shot)

        case .save:
            exportToDisk(image: image, shot: shot)
        }
    }

    private static func exportToDisk(image: CGImage, shot: Shot) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = defaultFileName(for: shot)
        panel.directoryURL = FileManager.default
            .urls(for: .desktopDirectory, in: .userDomainMask).first

        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? ImageCodec.pngData(from: image)?.write(to: url)
    }

    private static func defaultFileName(for shot: Shot) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let app = shot.appName.map { "-\($0)" } ?? ""
        return "截图 \(formatter.string(from: shot.capturedAt))\(app).png"
    }
}
