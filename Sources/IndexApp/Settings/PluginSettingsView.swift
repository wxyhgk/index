import SwiftUI

// MARK: - 插件管理面板
//
// 卡片式布局：每个插件一张卡片（图标 + 名称 + 描述 + 启停），
// Agent 配置区用独立面板，带状态指示。

struct PluginSettingsView: View {

    @ObservedObject private var settings = AppSettings.shared

    @State private var baseURL: String = ""
    @State private var model: String = ""
    @State private var apiKey: String = ""
    @State private var isLoaded = false
    @State private var saveTask: Task<Void, Never>?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.s5) {
                pluginGrid
                Divider()
                agentSection
                Divider()
                footerText
            }
            .padding(DS.s5)
        }
        .onAppear {
            if !isLoaded {
                baseURL = settings.plugin.agentBaseURL
                model = settings.plugin.agentModel
                apiKey = settings.plugin.agentAPIKey
                isLoaded = true
            }
        }
        .onChange(of: baseURL) { _, _ in scheduleSave() }
        .onChange(of: model) { _, _ in scheduleSave() }
        .onChange(of: apiKey) { _, _ in scheduleSave() }
    }

    // MARK: - 子视图

    private var pluginGrid: some View {
        VStack(alignment: .leading, spacing: DS.s3) {
            Text("插件")
                .font(.title3.weight(.semibold))

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: DS.s3)], spacing: DS.s3) {
                ForEach(knownPlugins, id: \.id) { plugin in
                    PluginCard(
                        plugin: plugin,
                        isEnabled: isPluginEnabled(plugin.id),
                        onToggle: { isOn in
                            setPluginEnabled(plugin.id, isOn)
                        }
                    )
                }
            }
        }
    }

    private var agentSection: some View {
        VStack(alignment: .leading, spacing: DS.s3) {
            agentHeader
            if settings.plugin.agentEnabled {
                agentConfigPanel
            }
        }
    }

    private var agentHeader: some View {
        HStack(spacing: DS.s2) {
            Image(systemName: "sparkles")
                .font(.title3)
                .foregroundStyle(settings.plugin.agentEnabled ? DS.accent : .secondary)
            Text("Agent")
                .font(.title3.weight(.semibold))
            Spacer()
            Toggle("", isOn: $settings.plugin.agentEnabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }

    private var agentConfigPanel: some View {
        VStack(alignment: .leading, spacing: DS.s4) {
            agentStatusRow
            LabeledField("端点") {
                TextField("https://api.openai.com/v1", text: $baseURL)
                    .textFieldStyle(.plain)
                    .font(.system(.body, design: .monospaced))
            }
            LabeledField("模型") {
                TextField("gpt-4o", text: $model)
                    .textFieldStyle(.plain)
                    .font(.system(.body, design: .monospaced))
            }
            LabeledField("API Key") {
                SecureField("sk-…", text: $apiKey)
                    .textFieldStyle(.plain)
                    .font(.system(.body, design: .monospaced))
            }
        }
        .padding(DS.s4)
        .background(DS.insetSurface)
        .clipShape(RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous))
    }

    private var agentStatusRow: some View {
        HStack(spacing: DS.s2) {
            Circle()
                .fill(agentPlugin.isConfigured ? Color.green : .orange)
                .frame(width: 8, height: 8)
            Text(agentPlugin.isConfigured ? "已就绪" : "需要配置 API Key")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var footerText: some View {
        Text("插件是 Index 的功能模块。关闭的插件不会在启动时激活，已激活的插件提供的快捷键、工具和内容类型将不可用。Agent 是特殊插件 —— 它能调用其他插件的能力，通过 LLM 对话帮你操作软件。")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - 插件数据

    fileprivate struct PluginInfo {
        let id: String
        let displayName: String
        let version: String
        let icon: String
        let description: String
    }

    private var knownPlugins: [PluginInfo] {
        [
            PluginInfo(id: "capture", displayName: "截图", version: "1.0", icon: "camera", description: "区域截图、滚动截图、延时截图"),
            PluginInfo(id: "recording", displayName: "录屏", version: "1.0", icon: "video", description: "屏幕录制、GIF 导出、步骤指南"),
            PluginInfo(id: "pin", displayName: "钉图", version: "1.0", icon: "pin", description: "截图钉在桌面上，支持穿透和缩放"),
            PluginInfo(id: "shelf", displayName: "暂存架", version: "1.0", icon: "tray", description: "截图后浮出小卡片，拖出即 PNG"),
            PluginInfo(id: "agent", displayName: "Agent", version: "1.0", icon: "sparkles", description: "AI 对话，自动调用工具查询截图和管理配置"),
        ]
    }

    private var agentPlugin: AgentPlugin { AgentPlugin.shared }

    // MARK: - 启停逻辑

    private func isPluginEnabled(_ id: String) -> Bool {
        let enabled = settings.enabledPluginIDs
        if enabled.isEmpty { return true }
        return enabled.contains(id)
    }

    private func setPluginEnabled(_ id: String, _ isOn: Bool) {
        var enabled = settings.enabledPluginIDs
        if enabled.isEmpty {
            enabled = knownPlugins.map(\.id)
        }
        if isOn {
            if !enabled.contains(id) { enabled.append(id) }
        } else {
            enabled.removeAll { $0 == id }
        }
        settings.plugin.enabledPluginIDs = enabled
    }

    // MARK: - 防抖落盘

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                settings.plugin.agentBaseURL = baseURL
                settings.plugin.agentModel = model
                settings.plugin.agentAPIKey = apiKey
            }
        }
    }
}

// MARK: - 插件卡片

private struct PluginCard: View {
    let plugin: PluginSettingsView.PluginInfo
    let isEnabled: Bool
    let onToggle: (Bool) -> Void

    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.s2) {
            HStack(spacing: DS.s2) {
                Image(systemName: plugin.icon)
                    .font(.title3)
                    .foregroundStyle(isEnabled ? DS.accent : .secondary)
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: DS.radiusSmall, style: .continuous)
                            .fill(isEnabled ? DS.accentFillSelected : DS.iconPlaceholderFill)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: DS.s1) {
                        Text(plugin.displayName)
                            .font(.body.weight(.medium))
                        Text("v\(plugin.version)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }

                Spacer()

                Toggle("", isOn: Binding(
                    get: { isEnabled },
                    set: { onToggle($0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
            }

            Text(plugin.description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(DS.s3)
        .background(
            RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous)
                .fill(hovering ? DS.hoverFill : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous)
                .strokeBorder(DS.borderSubtle, lineWidth: DS.hairline)
        )
        .onHover { hovering = $0 }
    }
}

// MARK: - 带标签的输入框

private struct LabeledField<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.s1) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            content
                .padding(.horizontal, DS.s3)
                .padding(.vertical, DS.s2)
                .background(
                    RoundedRectangle(cornerRadius: DS.radiusSmall, style: .continuous)
                        .fill(DS.insetSurface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DS.radiusSmall, style: .continuous)
                        .strokeBorder(DS.focusRingIdle, lineWidth: DS.hairline)
                )
        }
    }
}
