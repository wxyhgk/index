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
        // 宽度由宿主决定 —— 它现在嵌在图库窗口里（`GalleryView.settingsMode`），
        // 而不是从前那个固定 500pt 的独立窗口。只留一个下限防止分栏被压扁。
        .frame(minWidth: 460)
    }
}

// MARK: - 通用

private struct GeneralSettings: View {
    @ObservedObject var settings: AppSettings

    /// 麦克风权限被明确拒绝。开着「录制麦克风」却没权限时给出去系统设置的入口。
    @State private var microphoneDenied = false

    var body: some View {
        Form {
            Section("启动") {
                LaunchAtLoginRow()
            }

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

            Section {
                TextField(
                    "模板",
                    text: $settings.exportNameTemplate,
                    prompt: Text(AppSettings.defaultExportNameTemplate)
                )
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()

                Text("可用变量：{date} 日期、{time} 时间、{app} 来源 App（带前导连字符，无则为空）、{title} 窗口标题（截取 40 字符，自动去掉文件名非法字符）。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LabeledContent("预览") {
                    Text(templatePreview)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            } header: {
                Text("文件名")
            } footer: {
                Text("保存面板、图库导出和自动副本都用这个模板。")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Section("自动副本") {
                Toggle("截图后自动保存一份到指定文件夹", isOn: $settings.autoCopyEnabled)

                if settings.autoCopyEnabled {
                    LabeledContent("文件夹") {
                        HStack(spacing: 8) {
                            Text(settings.autoCopyDirectory.isEmpty ? "未选择" : settings.autoCopyDirectory)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Button("选择…") {
                                if let url = SystemNavigator.chooseDirectory(message: "选择副本保存的文件夹") {
                                    settings.autoCopyDirectory = url.path
                                }
                            }
                            .controlSize(.small)
                        }
                    }
                }

                Text("每张截图入库后自动写一份 PNG 副本，文件名走上面的模板，重名自动加序号。配合 Obsidian / 笔记软件的监听文件夹，截图直接进知识库。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("暂存卡片") {
                Toggle("截图后显示暂存卡片", isOn: $settings.showShelfCard)
                Text("截完图在屏幕右下角浮出小卡片，直接拖出去就是 PNG 文件，可以丢进聊天窗口或邮件。双击打开图库定位到这张，15 秒后自动消失。选「钉图」时不显示。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("自动美化") {
                Toggle("截图后自动加留白与阴影", isOn: $settings.autoBackdrop)
                Text("四周留出透明留白、内容切圆角、投一层柔和阴影 —— 贴进文档或聊天里就有成品感。拖拽选区和整窗截图（⌥+单击）都生效；带壳截图除外，壳自带边框与投影。留白是透明的，导出请用 PNG（JPEG 没有透明通道，会被压成黑底）。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if settings.autoBackdrop {
                    backdropSlider("留白", value: $settings.backdropPaddingRatio, range: 0...0.15)
                    backdropSlider("圆角", value: $settings.backdropCornerRatio, range: 0...0.06)
                    backdropSlider("阴影大小", value: $settings.backdropShadowRatio, range: 0...0.08)
                    LabeledContent("阴影浓度") {
                        HStack {
                            Slider(value: $settings.backdropShadowAlpha, in: 0.05...0.8)
                            Text("\(Int(settings.backdropShadowAlpha * 100))%")
                                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                                .frame(width: 84, alignment: .trailing)
                        }
                    }

                    Text("三项都是**图片短边的百分比**，不是固定像素 —— 小图和大图因此得到同样的观感，Retina 与非 Retina 也一致。")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if settings.backdropPaddingRatio < settings.backdropShadowRatio * 1.5 {
                        Label(
                            "留白比阴影小，阴影会被裁掉一圈 —— 建议留白至少是阴影的 1.5 倍。",
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                    }
                }
            }

            Section("图库") {
                Toggle("滚动时的深度效果", isOn: $settings.galleryScrollDepth)
                Text("卡片滚出视野时轻微淡出并后退，让内容有前后层次。截图上万张后如果滚动不跟手，关掉这项。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("选区") {
                Toggle("显示放大镜与取色器", isOn: $settings.showMagnifier)
                Text("拖选时在光标旁显示像素级预览、色值和坐标。按 C 复制色值。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("整窗截图") {
                Toggle("窗口截图带系统阴影", isOn: $settings.windowCaptureShadow)
                Text("选区时按住 ⌥ 单击窗口，可捕获不被遮挡的完整窗口，圆角外背景透明（PNG）。开启后连同系统渲染的阴影一起输出。")
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

            Section("录屏") {
                Toggle("录制系统声音", isOn: $settings.recordSystemAudio)
                Text("把其它 App 播放的声音一起写进视频。转 GIF 时音轨会被丢弃。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("录制麦克风", isOn: $settings.recordMicrophone)
                Text("首次开启会请求系统麦克风权限，录制用系统默认麦克风。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if settings.recordMicrophone && microphoneDenied {
                    HStack(spacing: 8) {
                        Text("麦克风权限被拒绝 —— 录出来的视频不会有麦克风声音。")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Button("打开系统设置") { MicrophonePermission.openSystemSettings() }
                            .controlSize(.small)
                    }
                }

                Toggle("录屏完成后保存到图库", isOn: $settings.recordingSaveToLibrary)
                Text("默认开启。图库用首帧显示录像，并提供播放、拖出和在访达中显示；视频文件本身仍保存在录屏目录。")
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
        // 勾选「录制麦克风」的当下就请求权限 —— 弹窗出现在用户做决定的时刻，
        // 而不是按下录制键的紧要关头。
        .onChange(of: settings.recordMicrophone) { _, enabled in
            if enabled {
                MicrophonePermission.request { _ in
                    microphoneDenied = MicrophonePermission.isDenied
                }
            }
        }
        .onAppear { microphoneDenied = MicrophonePermission.isDenied }
    }

    /// 用假数据渲染的示例 —— 和真实导出走同一份 `ImageExporter.renderName`，
    /// 预览和实际结果不可能漂移。
    private var templatePreview: String {
        ImageExporter.renderName(
            template: settings.exportNameTemplate,
            date: Date(),
            appName: "Safari",
            windowTitle: "MacShot 使用指南"
        ) + ".png"
    }

    /// 美化参数的滑杆。显示百分比，并换算成「1000px 短边的图上约等于多少像素」——
    /// 光给一个 5% 很难有手感，给个参照物就好判断了。
    private func backdropSlider(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>
    ) -> some View {
        LabeledContent(title) {
            HStack {
                Slider(value: value, in: range)
                Text("\(value.wrappedValue * 100, specifier: "%.1f")% · \(Int(value.wrappedValue * 1000))px")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    .frame(width: 84, alignment: .trailing)
            }
        }
    }
}

/// 「登录时启动」开关：绑定 `SMAppService` 的真实状态 ——
/// requiresApproval 也算开着（已注册，只是等系统放行），并给出系统设置入口；
/// 切换失败时开关随状态回读自动恢复原样，错误原文显示在下方。
private struct LaunchAtLoginRow: View {
    @State private var status = LaunchAtLogin.status
    @State private var errorText: String?

    var body: some View {
        Toggle("登录时启动 MacShot", isOn: Binding(
            get: { status == .enabled || status == .requiresApproval },
            set: { enable in
                errorText = nil
                do {
                    try LaunchAtLogin.setEnabled(enable)
                } catch {
                    errorText = "设置失败：\(error.localizedDescription)"
                }
                status = LaunchAtLogin.status
            }
        ))
        .onAppear { status = LaunchAtLogin.status }

        if status == .requiresApproval {
            HStack(spacing: 8) {
                Text("已注册，等待系统放行 —— 在「系统设置 › 通用 › 登录项」里允许 MacShot。")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Button("打开系统设置") { LaunchAtLogin.openSystemSettings() }
                    .controlSize(.small)
            }
        }
        if let errorText {
            Text(errorText)
                .font(.caption)
                .foregroundStyle(.red)
        }

        Text("注册为系统登录项，登录后自动出现在菜单栏。")
            .font(.caption)
            .foregroundStyle(.secondary)
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
                LabeledContent("3D 分子钉图") {
                    ShortcutRecorder(shortcut: $settings.moleculePinShortcut)
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
                Text("截图工具条常驻 指针 / 矩形 / 箭头 / 文字 / 马赛克，其余工具（含序号）按快捷键激活时临时出现。截图默认不选中任何工具；按 V 或点「指针」后可选中图层、并直接拖选画面里的文字（实况文本）。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("其它按键") {
                shortcutRow("⌘Z", "撤销标注")
                shortcutRow("⌘C / ⌘S", "复制 / 保存（指针模式下选中了文字则 ⌘C 复制文字）")
                shortcutRow("⏎", "确定（行为见「通用」）")
                shortcutRow("方向键", "微调选区，⇧ 十倍步进，⌥ 改尺寸")
                shortcutRow("⎋", "编辑后第一次退出编辑、第二次取消；中性态一次取消")
                shortcutRow("右键", "逐级退出：文字输入 → 图层选中 → 指针/工具 → 选区 → 取消")
            }

            Section("钉图窗口") {
                shortcutRow("⌘T", "切换鼠标穿透。穿透后点击落到下层窗口，从菜单栏「解除钉图穿透」恢复")
                shortcutRow("滚轮", "缩放钉图")
                shortcutRow("⌘滚轮", "调整透明度")
                shortcutRow("双击", "复制到剪贴板")
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
                                        ? DS.accent : DS.focusRingIdle,
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
                TextField("默认文案", text: $settings.watermarkText, prompt: Text("如 @your-name"))
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                Picker("默认位置", selection: $settings.watermarkMode) {
                    ForEach(WatermarkMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                HStack {
                    Slider(value: $settings.watermarkAlpha, in: 0.1...0.8) {
                        Text("透明度")
                    }
                    Text("\(Int(settings.watermarkAlpha * 100))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: 36, alignment: .trailing)
                }
                Toggle("导出自动加水印", isOn: $settings.autoWatermark)
            } header: {
                Text("水印")
            } footer: {
                Text("水印是一个图层：进修订链、可撤销、可在图库编辑器里删除。自动水印只作用于新截图，文案为空时不生效；工具条/编辑器里的手动开关不受这一项影响。")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
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
                            .strokeBorder(DS.focusRingIdle)
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
    @ObservedObject private var settings = AppSettings.shared
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

            Section("自动清理") {
                Toggle("自动清理旧截图", isOn: $settings.autoCleanupEnabled)

                Picker("保留时长", selection: $settings.autoCleanupDays) {
                    ForEach(AppSettings.autoCleanupChoices, id: \.self) { days in
                        Text("\(days) 天").tag(days)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(!settings.autoCleanupEnabled)

                Text("启动时删除超过保留时长的旧截图，每次最多 \(StorageJanitor.batchLimit) 张，删不完的下次接着删。收藏的、打过标签的和标注过的永远不删 —— 你亲手留下的痕迹反过来定义了什么值得留。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
