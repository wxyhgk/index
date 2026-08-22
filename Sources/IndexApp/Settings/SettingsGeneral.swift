import SwiftUI

struct GeneralSettings: View {
    @ObservedObject var settings: AppSettings
    @State private var microphoneDenied = false

    var body: some View {
        SettingsPage {
            // 截图行为：小卡片并排
            ToggleCardGrid {
                ToggleCard(label: "复制到剪贴板", icon: "doc.on.doc", isOn: $settings.capture.copyToClipboard)
                ToggleCard(label: "暂存卡片", icon: "tray", isOn: $settings.capture.showShelfCard)
                ToggleCard(label: "放大镜", icon: "magnifyingglass", isOn: $settings.capture.showMagnifier)
                ToggleCard(label: "整窗阴影", icon: "rectangle.portrait.on.rectangle.portrait", isOn: $settings.capture.windowCaptureShadow)
            }

            // 截图高级配置：大卡片
            SettingsCard("截图", icon: "camera") {
                Picker("回车", selection: $settings.capture.enterBehavior) {
                    ForEach(AppSettings.EnterBehavior.allCases) { b in
                        Text(b.title).tag(b)
                    }
                }
                .pickerStyle(.radioGroup)

                Picker("延时", selection: $settings.capture.captureDelay) {
                    ForEach(CapturePrefs.captureDelayChoices, id: \.self) { s in
                        Text("\(s)s").tag(s)
                    }
                }
                .pickerStyle(.segmented)
            }

            // 文件与美化：大卡片
            SettingsCard("文件", icon: "doc") {
                DebouncedTextField(
                    title: "模板",
                    placeholder: ExportPrefs.defaults.exportNameTemplate,
                    initialValue: settings.export.exportNameTemplate,
                    monospaced: true
                ) { settings.export.exportNameTemplate = $0 }

                LabeledContent("预览") {
                    Text(templatePreview)
                        .font(.system(size: DS.font11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                        .textSelection(.enabled)
                }

                SettingsRow("自动副本", icon: "arrow.down.doc") {
                    Toggle("", isOn: $settings.export.autoCopyEnabled)
                        .labelsHidden().toggleStyle(.switch)
                }
                if settings.export.autoCopyEnabled {
                    HStack(spacing: DS.s2) {
                        Text(settings.export.autoCopyDirectory.isEmpty ? "未选择" : settings.export.autoCopyDirectory)
                            .font(.system(size: DS.font11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                        Button("…") {
                            if let url = SystemNavigator.chooseDirectory(message: "选择文件夹") {
                                settings.export.autoCopyDirectory = url.path
                            }
                        }
                        .controlSize(.mini)
                    }
                }

                SettingsRow("自动美化", icon: "sparkles") {
                    Toggle("", isOn: $settings.annotationStyle.autoBackdrop)
                        .labelsHidden().toggleStyle(.switch)
                }
                if settings.annotationStyle.autoBackdrop {
                    HStack(spacing: DS.s2) {
                        Slider(value: $settings.annotationStyle.backdropPaddingRatio, in: 0...0.15)
                        Text("\(Int(settings.annotationStyle.backdropPaddingRatio * 1000))px")
                            .font(.system(size: DS.font10)).foregroundStyle(.secondary).monospacedDigit()
                            .frame(width: 40, alignment: .trailing)
                    }
                    HStack(spacing: DS.s2) {
                        Slider(value: $settings.annotationStyle.backdropShadowAlpha, in: 0.05...0.8)
                        Text("\(Int(settings.annotationStyle.backdropShadowAlpha * 100))%")
                            .font(.system(size: DS.font10)).foregroundStyle(.secondary).monospacedDigit()
                            .frame(width: 40, alignment: .trailing)
                    }
                }
            }

            // 智能识别：小卡片并排
            ToggleCardGrid {
                ToggleCard(label: "OCR 文字", icon: "text.viewfinder", isOn: $settings.intelligence.runOCR)
                ToggleCard(label: "敏感内容", icon: "eye.slash", isOn: $settings.intelligence.detectSensitive)
                ToggleCard(label: "自动分类", icon: "tag", isOn: $settings.intelligence.autoClassify)
                ToggleCard(label: "语义搜索", icon: "magnifyingglass.circle", isOn: $settings.intelligence.semanticSearch)
            }

            if settings.intelligence.semanticSearch {
                SettingsCard("语义搜索模型", icon: "brain") {
                    CLIPModelStatusRow()
                }
            }

            // 录屏：小卡片并排
            ToggleCardGrid {
                ToggleCard(label: "系统声音", icon: "speaker.wave.2", isOn: $settings.recording.recordSystemAudio)
                ToggleCard(label: "麦克风", icon: "mic", isOn: $settings.recording.recordMicrophone)
                ToggleCard(label: "保存到图库", icon: "square.and.arrow.down", isOn: $settings.recording.recordingSaveToLibrary)
            }

            if settings.recording.recordMicrophone && microphoneDenied {
                HStack(spacing: DS.s2) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: DS.font11)).foregroundStyle(.orange)
                    Button("打开系统设置") { MicrophonePermission.openSystemSettings() }
                        .controlSize(.mini)
                }
            }

            // 启动：小卡片
            ToggleCardGrid {
                LaunchAtLoginCard()
                ToggleCard(label: "滚动深度", icon: "square.stack.3d.up", isOn: $settings.library.galleryScrollDepth)
            }
        }
        .onChange(of: settings.intelligence.semanticSearch) { _, enabled in
            if enabled && CLIPModelStore.shared.isReady {
                AttributeBackfill.runIfNeeded(styleStore: settings)
            }
        }
        .onChange(of: settings.recording.recordMicrophone) { _, enabled in
            if enabled {
                MicrophonePermission.request { _ in
                    microphoneDenied = MicrophonePermission.isDenied
                }
            }
        }
        .onAppear { microphoneDenied = MicrophonePermission.isDenied }
    }

    private var templatePreview: String {
        ImageExporter.renderName(
            template: settings.export.exportNameTemplate,
            date: Date(), appName: "Safari", windowTitle: "Index"
        ) + ".png"
    }
}

// MARK: - 登录时启动小卡片

private struct LaunchAtLoginCard: View {
    @State private var status = LaunchAtLogin.status
    @State private var errorText: String?

    var body: some View {
        VStack(spacing: DS.s2) {
            HStack(spacing: DS.s2) {
                Image(systemName: "power")
                    .font(.system(size: DS.font12, weight: .medium))
                    .foregroundStyle(status == .enabled || status == .requiresApproval ? DS.accent : .secondary)
                    .frame(width: 26, height: 26)
                    .background(
                        RoundedRectangle(cornerRadius: DS.radiusSmall, style: .continuous)
                            .fill(status == .enabled || status == .requiresApproval ? DS.accentFillSelected : DS.iconPlaceholderFill)
                    )

                Text("登录时启动")
                    .font(.system(size: DS.font13, weight: .medium))
                    .lineLimit(1)

                Spacer(minLength: DS.s2)

                Toggle("", isOn: Binding(
                    get: { status == .enabled || status == .requiresApproval },
                    set: { enable in
                        errorText = nil
                        do { try LaunchAtLogin.setEnabled(enable) }
                        catch { errorText = error.localizedDescription }
                        status = LaunchAtLogin.status
                    }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
            }

            if status == .requiresApproval {
                HStack(spacing: DS.s1) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: DS.font10)).foregroundStyle(.orange)
                    Button("打开系统设置") { LaunchAtLogin.openSystemSettings() }
                        .controlSize(.mini)
                }
            }
            if let errorText {
                Text(errorText).font(.system(size: DS.font10)).foregroundStyle(.red).lineLimit(1)
            }
        }
        .padding(DS.s3)
        .background(
            RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous)
                .fill(DS.panelFill(.resting))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous)
                .strokeBorder(DS.borderSubtle, lineWidth: DS.hairline)
        )
        .onAppear { status = LaunchAtLogin.status }
    }
}

// MARK: - 语义搜索模型状态

private struct CLIPModelStatusRow: View {
    @ObservedObject private var modelStore = CLIPModelStore.shared

    var body: some View {
        HStack(spacing: DS.s2) {
            switch modelStore.state {
            case .notDownloaded:
                Button("下载模型") { Task { await download() } }
                    .controlSize(.mini)
            case .downloading(let progress):
                ProgressView(value: progress).frame(width: 80)
                Text("\(Int(progress * 100))%")
                    .font(.system(size: DS.font11)).foregroundStyle(.secondary)
            case .compiling:
                ProgressView().controlSize(.mini)
                Text("编译中…").font(.system(size: DS.font11)).foregroundStyle(.secondary)
            case .ready(let bytes):
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: DS.font12)).foregroundStyle(.green)
                Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                    .font(.system(size: DS.font11)).foregroundStyle(.secondary)
                Button("删除") { Task { await modelStore.removeModels() } }
                    .controlSize(.mini)
            case .failed:
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: DS.font12)).foregroundStyle(.red)
                Button("重试") { Task { await download() } }
                    .controlSize(.mini)
            }
        }
    }

    private func download() async {
        await modelStore.ensureModels()
        if modelStore.isReady {
            AttributeBackfill.runIfNeeded(styleStore: AppSettings.shared)
        }
    }
}
