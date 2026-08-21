import AppKit

/// 上传图床：截完 → 上传 → 链接进剪贴板。
///
/// 走通用自定义 HTTP API（PicGo / uPic 兼容图床、Cloudflare Workers 自建、
/// Chevereto 等都能覆盖），配置在「设置 → 上传」。
///
/// 已知取舍：上传期间没有进度 UI —— 动作触发后选区层已经关闭，成功的反馈就是
/// 链接出现在剪贴板（外加一条 NSLog）；失败会走协调器的错误弹窗。
struct UploadAction: CaptureAction {
    let id = ActionID.upload
    let title = "上传"
    let symbolName = "arrow.up.circle"
    let scopes: Set<ActionScope> = [.capture, .pinned]
    /// 用户要的是链接不是图片，全局自动复制不许来盖一次。
    let suppressesAutoCopy = true
    /// 低频动作，收进截图工具条的「更多」菜单（钉图不折叠）。
    let isPrimaryAction = false

    /// 图床配置。注入式：装配点（registerBuiltins）传窄协议切片。
    private let upload: any UploadPreferences

    init(upload: any UploadPreferences) {
        self.upload = upload
    }

    func perform(_ context: CaptureContext) async throws {
        let config = UploadConfig(
            endpoint: upload.uploadEndpoint,
            fieldName: upload.uploadFieldName,
            headersText: upload.uploadHeaders,
            responsePath: upload.uploadResponsePath
        )

        guard let png = ImageCodec.pngData(from: context.rendered()) else {
            throw UploadError.encodeFailed
        }

        let link = try await ImageUploader.upload(
            png: png,
            filename: Self.filename(for: context.shot),
            config: config
        )

        Clipboard.copy(text: upload.uploadLinkFormat.format(link))
        NSLog("[Index] 上传成功，链接已复制: \(link)")
    }

    private static func filename(for shot: Shot?) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "index-\(formatter.string(from: shot?.capturedAt ?? Date())).png"
    }
}
