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
                ForEach(BuiltinPluginCatalog.shared.all) { plugin in
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
            if isPluginEnabled("agent") {
                agentConfigPanel
            } else {
                Text("在上方启用 Agent 插件后可配置模型。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var agentHeader: some View {
        HStack(spacing: DS.s2) {
            Image(systemName: "sparkles")
                .font(.title3)
                .foregroundStyle(isPluginEnabled("agent") ? DS.accent : .secondary)
            Text("Agent")
                .font(.title3.weight(.semibold))
            Spacer()
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
        Text("插件是 Index 的功能模块。输入即检索支持当前进程即时启停；其他插件关闭后不会在下次启动时激活。Agent 能调用其他插件的能力，通过 LLM 对话帮你操作软件。")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - 插件数据

    private var agentPlugin: AgentPlugin { AgentPlugin.shared }

    // MARK: - 启停逻辑

    private func isPluginEnabled(_ id: String) -> Bool {
        settings.enabledPluginIDs.contains(id)
    }

    private func setPluginEnabled(_ id: String, _ isOn: Bool) {
        var prefs = settings.plugin
        var enabled = prefs.enabledPluginIDs
        if isOn {
            if !enabled.contains(id) { enabled.append(id) }
        } else {
            enabled.removeAll { $0 == id }
        }
        prefs.enabledPluginIDs = enabled
        if id == "agent" { prefs.agentEnabled = isOn }
        settings.plugin = prefs
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
    let plugin: BuiltinPluginDescriptor
    let isEnabled: Bool
    let onToggle: (Bool) -> Void

    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.s2) {
            HStack(spacing: DS.s2) {
                Image(systemName: plugin.symbolName)
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

            Text(plugin.summary)
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
