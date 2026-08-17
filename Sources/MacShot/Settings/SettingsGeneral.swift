import SwiftUI

// MARK: - 通用

struct GeneralSettings: View {
    @ObservedObject var settings: AppSettings

    /// 麦克风权限被明确拒绝。开着「录制麦克风」却没权限时给出去系统设置的入口。
    @State private var microphoneDenied = false

    var body: some View {
        Form {
            Section("启动") {
                LaunchAtLoginRow()
            }

            Section {
                Picker("按回车时", selection: $settings.capture.enterBehavior) {
                    ForEach(AppSettings.EnterBehavior.allCases) { behavior in
                        Text(behavior.title).tag(behavior)
                    }
                }
                .pickerStyle(.radioGroup)

                Text(settings.capture.enterBehavior.detail)
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
                Toggle("点击钉图 / 保存时也复制到剪贴板", isOn: $settings.capture.copyToClipboard)
                Text("回车的行为由上面的设置决定，不受这一项影响。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                TextField(
                    "模板",
                    text: $settings.export.exportNameTemplate,
                    prompt: Text(ExportPrefs.defaults.exportNameTemplate)
                )
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()

                Text("可用变量：{dateCompact} 紧凑日期、{timeCompact} 紧凑时间、{date} 日期、{time} 时间、{app} 来源 App、{title} 窗口标题、{name} 图库显示名称。")
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
                Toggle("截图后自动保存一份到指定文件夹", isOn: $settings.export.autoCopyEnabled)

                if settings.export.autoCopyEnabled {
                    LabeledContent("文件夹") {
                        HStack(spacing: 8) {
                            Text(settings.export.autoCopyDirectory.isEmpty ? "未选择" : settings.export.autoCopyDirectory)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Button("选择…") {
                                if let url = SystemNavigator.chooseDirectory(message: "选择副本保存的文件夹") {
                                    settings.export.autoCopyDirectory = url.path
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
                Toggle("截图后显示暂存卡片", isOn: $settings.capture.showShelfCard)
                Text("截完图在屏幕右下角浮出小卡片，直接拖出去就是 PNG 文件，可以丢进聊天窗口或邮件。双击打开图库定位到这张，15 秒后自动消失。选「钉图」时不显示。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("自动美化") {
                Toggle("截图后自动加留白与阴影", isOn: $settings.annotationStyle.autoBackdrop)
                Text("四周留出透明留白、内容切圆角、投一层柔和阴影 —— 贴进文档或聊天里就有成品感。拖拽选区和整窗截图（⌥+单击）都生效；带壳截图除外，壳自带边框与投影。留白是透明的，导出请用 PNG（JPEG 没有透明通道，会被压成黑底）。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if settings.annotationStyle.autoBackdrop {
                    backdropSlider("留白", value: $settings.annotationStyle.backdropPaddingRatio, range: 0...0.15)
                    backdropSlider("圆角", value: $settings.annotationStyle.backdropCornerRatio, range: 0...0.06)
                    backdropSlider("阴影大小", value: $settings.annotationStyle.backdropShadowRatio, range: 0...0.08)
                    LabeledContent("阴影浓度") {
                        HStack {
                            Slider(value: $settings.annotationStyle.backdropShadowAlpha, in: 0.05...0.8)
                            Text("\(Int(settings.annotationStyle.backdropShadowAlpha * 100))%")
                                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                                .frame(width: 84, alignment: .trailing)
                        }
                    }

                    Text("三项都是**图片短边的百分比**，不是固定像素 —— 小图和大图因此得到同样的观感，Retina 与非 Retina 也一致。")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if settings.annotationStyle.backdropPaddingRatio < settings.annotationStyle.backdropShadowRatio * 1.5 {
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
                Toggle("滚动时的深度效果", isOn: $settings.library.galleryScrollDepth)
                Text("卡片较少时，滚出视野会轻微淡出并后退。为控制内存与合成开销，超过 60 张时自动停用。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("选区") {
                Toggle("显示放大镜与取色器", isOn: $settings.capture.showMagnifier)
                Text("拖选时在光标旁显示像素级预览、色值和坐标。按 C 复制色值。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("整窗截图") {
                Toggle("窗口截图带系统阴影", isOn: $settings.capture.windowCaptureShadow)
                Text("选区时按住 ⌥ 单击窗口，可捕获不被遮挡的完整窗口，圆角外背景透明（PNG）。开启后连同系统渲染的阴影一起输出。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("延时截图") {
                Picker("等待时长", selection: $settings.capture.captureDelay) {
                    ForEach(CapturePrefs.captureDelayChoices, id: \.self) { seconds in
                        Text("\(seconds) 秒").tag(seconds)
                    }
                }
                .pickerStyle(.segmented)
                Text("倒计时显示在屏幕右下角。按 ⎋、点击倒计时或再按一次快捷键取消。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("录屏") {
                Toggle("录制系统声音", isOn: $settings.recording.recordSystemAudio)
                Text("把其它 App 播放的声音一起写进视频。转 GIF 时音轨会被丢弃。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("录制麦克风", isOn: $settings.recording.recordMicrophone)
                Text("首次开启会请求系统麦克风权限，录制用系统默认麦克风。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if settings.recording.recordMicrophone && microphoneDenied {
                    HStack(spacing: 8) {
                        Text("麦克风权限被拒绝 —— 录出来的视频不会有麦克风声音。")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Button("打开系统设置") { MicrophonePermission.openSystemSettings() }
                            .controlSize(.small)
                    }
                }

                Toggle("录屏完成后保存到图库", isOn: $settings.recording.recordingSaveToLibrary)
                Text("默认开启。图库用首帧显示录像，并提供播放、拖出和在访达中显示；视频文件本身仍保存在录屏目录。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("识别") {
                Toggle("自动识别截图中的文字", isOn: $settings.intelligence.runOCR)
                Text("在后台运行，识别结果进入全文索引，可以直接搜截图里的字。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("检测敏感内容", isOn: $settings.intelligence.detectSensitive)
                Text("自动发现截图里的邮箱、密钥、银行卡号、手机号和人脸，详情页可一键打码。检测在本机完成，具体内容不进入搜索索引。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("自动分类", isOn: $settings.intelligence.autoClassify)
                Text("按来源 App 归入代码、浏览器、聊天等分类，并附加系统 Vision 场景标签。图库里可按分类筛选，分类名也可直接搜索。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("语义搜索", isOn: $settings.intelligence.semanticSearch)
                Text("用自然语言描述画面来搜截图，如 “blue gradient dashboard”。需要下载 MobileCLIP 模型（约 111 MB），推理全部在本机完成。模型为英文训练，英文描述效果最好。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if settings.intelligence.semanticSearch {
                    CLIPModelStatusRow()
                }
            }
        }
        .formStyle(.grouped)
        // 模型已在而开关后开：老截图的向量此刻才轮到补。
        .onChange(of: settings.intelligence.semanticSearch) { _, enabled in
            if enabled && CLIPModelStore.shared.isReady {
                AttributeBackfill.runIfNeeded(styleStore: settings)
            }
        }
        // 勾选「录制麦克风」的当下就请求权限 —— 弹窗出现在用户做决定的时刻，
        // 而不是按下录制键的紧要关头。
        .onChange(of: settings.recording.recordMicrophone) { _, enabled in
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
            template: settings.export.exportNameTemplate,
            date: Date(),
            appName: "Safari",
            windowTitle: "Index 使用指南"
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
        Toggle("登录时启动 Index", isOn: Binding(
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
                Text("已注册，等待系统放行 —— 在「系统设置 › 通用 › 登录项」里允许 Index。")
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
            AttributeBackfill.runIfNeeded(styleStore: AppSettings.shared)
        }
    }
}
