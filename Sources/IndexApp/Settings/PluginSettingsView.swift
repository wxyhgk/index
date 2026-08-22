import SwiftUI

// MARK: - 插件管理面板
//
// 设置页的"插件"Tab：
//   · 插件列表（启停开关）
//   · Agent 配置（LLM 端点 / 模型 / API key / 启用开关）

struct PluginSettingsView: View {

    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Form {
            // MARK: 插件列表
            Section("插件") {
                ForEach(knownPlugins, id: \.id) { plugin in
                    Toggle(isOn: binding(for: plugin.id)) {
                        HStack {
                            Text(plugin.displayName)
                            Text("v\(plugin.version)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            // MARK: Agent 配置
            Section("Agent") {
                Toggle("启用 Agent", isOn: $settings.plugin.agentEnabled)

                if settings.plugin.agentEnabled {
                    TextField("端点", text: $settings.plugin.agentBaseURL)
                        .textFieldStyle(.roundedBorder)
                    TextField("模型", text: $settings.plugin.agentModel)
                        .textFieldStyle(.roundedBorder)
                    SecureField("API Key", text: $settings.plugin.agentAPIKey)
                        .textFieldStyle(.roundedBorder)

                    Text("Agent 可以调用工具查询截图、管理插件、修改配置。需要配置 OpenAI 兼容的 LLM 端点。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    /// 已知插件列表（id / 名称 / 版本）。
    private var knownPlugins: [(id: String, displayName: String, version: String)] {
        [
            ("capture", "截图", "1.0"),
            ("recording", "录屏", "1.0"),
            ("pin", "钉图", "1.0"),
            ("shelf", "暂存架", "1.0"),
            ("agent", "Agent", "1.0"),
        ]
    }

    /// 启停绑定：空列表 = 全部启用；非空 = 只启用列表里的。
    private func binding(for pluginID: String) -> Binding<Bool> {
        Binding(
            get: {
                let enabled = settings.enabledPluginIDs
                if enabled.isEmpty { return true }
                return enabled.contains(pluginID)
            },
            set: { isOn in
                var enabled = settings.enabledPluginIDs
                // 空列表 = 全部启用，第一次操作时展开为完整列表
                if enabled.isEmpty {
                    enabled = knownPlugins.map(\.id)
                }
                if isOn {
                    if !enabled.contains(pluginID) { enabled.append(pluginID) }
                } else {
                    enabled.removeAll { $0 == pluginID }
                }
                settings.plugin.enabledPluginIDs = enabled
            }
        )
    }
}
