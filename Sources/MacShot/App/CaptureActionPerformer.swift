import AppKit

/// 执行工具条上的动作。
/// 单独拆出来是因为这一层是**副作用的集散地** —— 钉图窗口、剪贴板、存盘面板、编辑器窗口，
/// 每一个都是不同的子系统。混在截图流程里会让流程本身无法阅读。
@MainActor
enum CaptureActionPerformer {

    /// 传的是**未标注的底图 + 图层**而不是合成结果 —— 钉图窗口需要它们才能继续非破坏性地画。
    static func perform(
        _ action: ToolbarAction,
        base: CGImage,
        layers: [Layer],
        shot: Shot,
        region: CGRect
    ) {
        switch action {
        case .pin:
            PinWindowController.pin(base: base, layers: layers, shot: shot, at: region)

        case .copy:
            ImageCodec.copyToPasteboard(flattened(base: base, layers: layers))

        case .save:
            exportToDisk(image: flattened(base: base, layers: layers), shot: shot)

        case .close, .done:
            break   // 截图已经入库了，这两个不需要额外动作
        }
    }

    private static func flattened(base: CGImage, layers: [Layer]) -> CGImage {
        layers.isEmpty ? base : LayerRenderer.render(base: base, layers: layers)
    }

    /// 钉图窗口的「保存」也走这里，避免两处各写一遍存盘面板。
    static func exportToDisk(image: CGImage, shot: Shot) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = defaultFileName(for: shot)
        panel.directoryURL = FileManager.default
            .urls(for: .desktopDirectory, in: .userDomainMask).first

        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? ImageCodec.pngData(from: image)?.write(to: url)
    }

    static func defaultFileName(for shot: Shot) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let app = shot.appName.map { "-\($0)" } ?? ""
        return "截图 \(formatter.string(from: shot.capturedAt))\(app).png"
    }
}
