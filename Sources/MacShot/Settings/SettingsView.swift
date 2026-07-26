import SwiftUI

struct SettingsView: View {

    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        TabView {
            GeneralSettings(settings: settings)
                .tabItem { Label("通用", systemImage: "gearshape") }
            ShortcutSettings(settings: settings)
                .tabItem { Label("快捷键", systemImage: "command") }
            AnnotationSettings(settings: settings)
                .tabItem { Label("标注", systemImage: "pencil.tip") }
            UploadSettings(settings: settings)
                .tabItem { Label("上传", systemImage: "square.and.arrow.up") }
            StorageSettings()
                .tabItem { Label("存储", systemImage: "internaldrive") }
        }
        .frame(width: 500)
    }
}

// MARK: - 通用

private struct GeneralSettings: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section {
                Picker("按回车时", selection: $settings.enterBehavior) {
                    ForEach(AppSettings.EnterBehavior.allCases) { behavior in
                        Text(behavior.title).tag(behavior)
                    }
                }
                .pickerStyle(.radioGroup)

                Text(settings.enterBehavior.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("确定键")
            } footer: {
                Text("回车没有绑定钉图：误触发复制最多覆盖剪贴板，误触发钉图会凭空多出一个窗口。")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Section("剪贴板") {
                Toggle("点击钉图 / 保存时也复制到剪贴板", isOn: $settings.copyToClipboard)
                Text("回车的行为由上面的设置决定，不受这一项影响。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("选区") {
                Toggle("显示放大镜与取色器", isOn: $settings.showMagnifier)
                Text("拖选时在光标旁显示像素级预览、色值和坐标。按 C 复制色值。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("延时截图") {
                Picker("等待时长", selection: $settings.captureDelay) {
                    ForEach(AppSettings.captureDelayChoices, id: \.self) { seconds in
                        Text("\(seconds) 秒").tag(seconds)
                    }
                }
                .pickerStyle(.segmented)
                Text("倒计时显示在屏幕右下角。按 ⎋、点击倒计时或再按一次快捷键取消。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("识别") {
                Toggle("自动识别截图中的文字", isOn: $settings.runOCR)
                Text("在后台运行，识别结果进入全文索引，可以直接搜截图里的字。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("检测敏感内容", isOn: $settings.detectSensitive)
                Text("自动发现截图里的邮箱、密钥、银行卡号、手机号和人脸，详情页可一键打码。检测在本机完成，具体内容不进入搜索索引。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("自动分类", isOn: $settings.autoClassify)
                Text("按来源 App 归入代码、浏览器、聊天等分类，并附加系统 Vision 场景标签。图库里可按分类筛选，分类名也可直接搜索。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("语义搜索", isOn: $settings.semanticSearch)
                Text("用自然语言描述画面来搜截图，如 “blue gradient dashboard”。需要下载 MobileCLIP 模型（约 111 MB），推理全部在本机完成。模型为英文训练，英文描述效果最好。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if settings.semanticSearch {
                    CLIPModelStatusRow()
                }
            }
        }
        .formStyle(.grouped)
        // 模型已在而开关后开：老截图的向量此刻才轮到补。
        .onChange(of: settings.semanticSearch) { _, enabled in
            if enabled && CLIPModelStore.shared.isReady {
                AttributeBackfill.runIfNeeded()
            }
        }
    }
}

/// 语义搜索模型的状态与管理：未下载 → 下载按钮 + 进度；已就绪 → 占用大小 + 删除。
private struct CLIPModelStatusRow: View {
    @ObservedObject private var modelStore = CLIPModelStore.shared

    var body: some View {
        LabeledContent("模型") {
            switch modelStore.state {
            case .notDownloaded:
                Button("下载模型（约 \(Self.totalText)）") {
                    Task { await download() }
                }
                .controlSize(.small)

            case .downloading(let progress):
                HStack(spacing: 8) {
                    ProgressView(value: progress)
                        .frame(width: 120)
                    Text("\(Int(progress * 100))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

            case .compiling:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("编译中…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

            case .ready(let diskBytes):
                HStack(spacing: 8) {
                    Label(
                        "已就绪 · \(ByteCountFormatter.string(fromByteCount: diskBytes, countStyle: .file))",
                        systemImage: "checkmark.circle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.green)
                    Button("删除") {
                        Task { await modelStore.removeModels() }
                    }
                    .controlSize(.small)
                }

            case .failed(let message):
                VStack(alignment: .trailing, spacing: 4) {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                    Button("重试") {
                        Task { await download() }
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    private static let totalText = ByteCountFormatter.string(
        fromByteCount: CLIPModelStore.totalDownloadBytes,
        countStyle: .file
    )

    /// 下载完成即刻给老截图回填向量 —— 否则语义搜索开着却搜不到任何东西。
    private func download() async {
        await modelStore.ensureModels()
        if modelStore.isReady {
            AttributeBackfill.runIfNeeded()
        }
    }
}

// MARK: - 快捷键

private struct ShortcutSettings: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section("全局快捷键") {
                LabeledContent("截图") {
                    ShortcutRecorder(shortcut: $settings.captureShortcut)
                        .frame(width: 130, height: 24)
                }
                LabeledContent("延时截图") {
                    ShortcutRecorder(shortcut: $settings.delayedCaptureShortcut)
                        .frame(width: 130, height: 24)
                }
                LabeledContent("录屏") {
                    ShortcutRecorder(shortcut: $settings.recordingShortcut)
                        .frame(width: 130, height: 24)
                }
                LabeledContent("滚动截图") {
                    ShortcutRecorder(shortcut: $settings.scrollCaptureShortcut)
                        .frame(width: 130, height: 24)
                }
                LabeledContent("打开图库") {
                    ShortcutRecorder(shortcut: $settings.galleryShortcut)
                        .frame(width: 130, height: 24)
                }

                HStack {
                    Spacer()
                    Button("恢复默认") { settings.resetShortcuts() }
                        .controlSize(.small)
                }

                Text("点一下方框，然后按下新的组合键。必须包含至少一个修饰键。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("标注工具") {
                // 从 AnnotationTool.shortcuts 生成 —— 此前这里是手写的第三份清单，
                // 改了实际映射它不会跟着变。
                ForEach(AnnotationTool.shortcuts, id: \.keyCode) { shortcut in
                    shortcutRow(shortcut.label, shortcut.toolName)
                }
            }

            Section("其它按键") {
                shortcutRow("⌘Z", "撤销标注")
                shortcutRow("⌘C / ⌘S", "复制 / 保存")
                shortcutRow("⏎", "确定（行为见「通用」）")
                shortcutRow("方向键", "微调选区，⇧ 十倍步进，⌥ 改尺寸")
                shortcutRow("右键", "逐级退出：文字输入 → 工具 → 选区")
                shortcutRow("⎋", "取消")
            }
        }
        .formStyle(.grouped)
    }

    private func shortcutRow(_ key: String, _ description: String) -> some View {
        LabeledContent {
            Text(description)
                .font(.caption)
                .foregroundStyle(.secondary)
        } label: {
            Text(key)
                .font(.system(.caption, design: .monospaced))
        }
    }
}

// MARK: - 标注

private struct AnnotationSettings: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section("默认颜色") {
                HStack(spacing: 10) {
                    ForEach(AnnotationState.palette.indices, id: \.self) { index in
                        let color = AnnotationState.palette[index]
                        Circle()
                            .fill(Color(.sRGB, red: color.r, green: color.g, blue: color.b))
                            .frame(width: 22, height: 22)
                            .overlay {
                                Circle().strokeBorder(
                                    settings.defaultColorIndex == index
                                        ? Color.accentColor : Color.primary.opacity(0.15),
                                    lineWidth: settings.defaultColorIndex == index ? 3 : 1
                                )
                            }
                            .onTapGesture { settings.defaultColorIndex = index }
                    }
                    Spacer()
                }
            }

            Section("默认粗细") {
                Picker("", selection: $settings.defaultWidthIndex) {
                    ForEach(AnnotationState.widths.indices, id: \.self) { index in
                        Text("\(Int(AnnotationState.widths[index])) pt").tag(index)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            Section {
                Text("原图永远不会被修改。标注以图层形式存成修订，每次编辑都是追加一条记录，可以无限回溯。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("关于标注")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - 上传

private struct UploadSettings: View {
    @ObservedObject var settings: AppSettings

    @State private var isTesting = false
    @State private var testResult: String?
    @State private var testSucceeded = false

    var body: some View {
        Form {
            Section {
                TextField("接口地址", text: $settings.uploadEndpoint, prompt: Text("https://example.com/upload"))
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                TextField("文件字段名", text: $settings.uploadFieldName, prompt: Text("file"))
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
            } header: {
                Text("接口")
            } footer: {
                Text("multipart/form-data POST。兼容 PicGo / uPic 自定义 API、Cloudflare Workers 自建、Chevereto 等；不支持 S3 直传签名。")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Section {
                TextEditor(text: $settings.uploadHeaders)
                    .font(.system(.caption, design: .monospaced))
                    .frame(height: 60)
                    .autocorrectionDisabled()
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(Color.primary.opacity(0.15))
                    )
            } header: {
                Text("请求头")
            } footer: {
                Text("每行一条，如 Authorization: Bearer xxx。明文保存在本机偏好设置里。")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Section("响应与链接") {
                TextField("链接路径", text: $settings.uploadResponsePath, prompt: Text("如 data.url，留空则整个响应体即链接"))
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                Picker("剪贴板格式", selection: $settings.uploadLinkFormat) {
                    ForEach(AppSettings.UploadLinkFormat.allCases) { format in
                        Text(format.title).tag(format)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section {
                HStack {
                    Button(isTesting ? "上传中…" : "测试上传") { runTest() }
                        .disabled(isTesting || settings.uploadEndpoint.trimmingCharacters(in: .whitespaces).isEmpty)
                    if isTesting {
                        ProgressView().controlSize(.small)
                    }
                }
                if let testResult {
                    Text(testResult)
                        .font(.caption)
                        .foregroundStyle(testSucceeded ? Color.green : Color.red)
                        .textSelection(.enabled)
                }
            } header: {
                Text("测试")
            } footer: {
                Text("会往图床传一张 1×1 像素的 PNG 验证配置。")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .formStyle(.grouped)
    }

    private func runTest() {
        guard let png = Self.makeTestPNG() else {
            testResult = "生成测试图片失败"
            testSucceeded = false
            return
        }
        let config = UploadConfig(
            endpoint: settings.uploadEndpoint,
            fieldName: settings.uploadFieldName,
            headersText: settings.uploadHeaders,
            responsePath: settings.uploadResponsePath
        )
        isTesting = true
        testResult = nil
        Task {
            do {
                let link = try await ImageUploader.upload(
                    png: png, filename: "macshot-test.png", config: config
                )
                testResult = "成功：\(link)"
                testSucceeded = true
            } catch {
                testResult = error.localizedDescription
                testSucceeded = false
            }
            isTesting = false
        }
    }

    private static func makeTestPNG() -> Data? {
        guard let context = CGContext(
            data: nil, width: 1, height: 1,
            bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard let image = context.makeImage() else { return nil }
        return ImageCodec.pngData(from: image)
    }
}

// MARK: - 存储

private struct StorageSettings: View {
    @State private var totalSize: String = "计算中…"
    @State private var shotCount: Int = 0

    private let store = ShotStore.shared

    var body: some View {
        Form {
            Section("位置") {
                LabeledContent("目录") {
                    Text(store.rootDirectory.path)
                        .font(.caption)
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                Button("在访达中显示") {
                    SystemNavigator.revealInFinder(store.rootDirectory)
                }
                .controlSize(.small)
            }

            Section("占用") {
                LabeledContent("截图数量", value: "\(shotCount)")
                LabeledContent("磁盘占用", value: totalSize)
            }

            Section {
                Text("原图按内容哈希存放，同样的画面只会占一份空间。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { await measure() }
    }

    private func measure() async {
        shotCount = store.shots.count
        let root = store.rootDirectory
        let bytes = await Task.detached(priority: .utility) {
            directorySize(of: root)
        }.value
        totalSize = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

private func directorySize(of url: URL) -> Int64 {
    guard let enumerator = FileManager.default.enumerator(
        at: url,
        includingPropertiesForKeys: [.fileSizeKey],
        options: [.skipsHiddenFiles]
    ) else { return 0 }

    var total: Int64 = 0
    for case let fileURL as URL in enumerator {
        let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        total += Int64(size)
    }
    return total
}
