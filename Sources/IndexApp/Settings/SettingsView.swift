import SwiftUI

// MARK: - 设置页
//
// 胶囊式 tab 栏（和图库顶栏同一视觉语言）+ 卡片式内容区。
// 不再用系统 TabView —— 它的默认样式和软件的"深底 + 浮起面板"风格不搭。

struct SettingsView: View {

    @State private var selectedTab: SettingsTab = .general
    @State private var loadedTabs: Set<SettingsTab> = [.general]

    var body: some View {
        VStack(spacing: 0) {
            // 胶囊 tab 栏
            HStack(spacing: DS.s1 / 2) {
                ForEach(SettingsTab.allCases, id: \.self) { tab in
                    SettingsTabButton(
                        title: tab.title,
                        symbol: tab.symbol,
                        isSelected: selectedTab == tab
                    ) {
                        selectedTab = tab
                    }
                }
            }
            .padding(DS.s1 / 2)
            .background(DS.trayFill(colorScheme), in: Capsule())
            .fixedSize()
            .padding(.top, DS.s1)
            .padding(.bottom, DS.s3)

            // 内容区：ZStack 保持已访问 tab alive（切换 instant），
            // 非当前 tab 用 opacity 隐藏（保留正常高度，避免 NSTextField 丢失粘贴能力）
            ZStack(alignment: .top) {
                ForEach(SettingsTab.allCases, id: \.self) { tab in
                    if loadedTabs.contains(tab) {
                        tabContent(tab)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                            .opacity(tab == selectedTab ? 1 : 0)
                            .allowsHitTesting(tab == selectedTab)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(minWidth: 460)
        .onChange(of: selectedTab) { _, newTab in
            loadedTabs.insert(newTab)
        }
    }

    @ViewBuilder
    private func tabContent(_ tab: SettingsTab) -> some View {
        switch tab {
        case .general:
            GeneralSettings(settings: AppSettings.shared)
        case .shortcuts:
            ShortcutSettings(settings: AppSettings.shared)
        case .annotation:
            AnnotationSettings(settings: AppSettings.shared)
        case .ai:
            SelectionAISettings(settings: AppSettings.shared)
        case .upload:
            UploadSettings(settings: AppSettings.shared)
        case .plugins:
            PluginSettingsView()
        case .storage:
            StorageSettings()
        }
    }

    @Environment(\.colorScheme) private var colorScheme
}

// MARK: - Tab 定义

private enum SettingsTab: String, CaseIterable, Identifiable {
    case general, shortcuts, annotation, ai, upload, plugins, storage

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general:    return "通用"
        case .shortcuts:  return "快捷键"
        case .annotation: return "标注"
        case .ai:         return "AI"
        case .upload:     return "上传"
        case .plugins:    return "插件"
        case .storage:    return "存储"
        }
    }

    var symbol: String {
        switch self {
        case .general:    return "gearshape"
        case .shortcuts:  return "command"
        case .annotation: return "pencil.tip"
        case .ai:         return "sparkles"
        case .upload:     return "square.and.arrow.up"
        case .plugins:    return "puzzlepiece.extension"
        case .storage:    return "internaldrive"
        }
    }
}

// MARK: - 胶囊 tab 按钮（和图库 DestinationTab 同一风格）

private struct SettingsTabButton: View {
    let title: String
    let symbol: String
    let isSelected: Bool
    let action: () -> Void

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: DS.s1) {
                Image(systemName: symbol)
                    .font(.system(size: DS.font12, weight: .medium))
                Text(title)
                    .font(.system(size: DS.font13, weight: isSelected ? .medium : .regular))
            }
            .foregroundStyle(isSelected ? Color.primary : Color.secondary)
            .padding(.horizontal, DS.s3)
            .frame(height: DS.s4 + DS.s3)
            .background(fill, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(DS.Motion.micro(reduced: reduceMotion), value: hovering)
        .animation(DS.Motion.micro(reduced: reduceMotion), value: isSelected)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private var fill: Color {
        if isSelected {
            return DS.tabSelectedFill(scheme)
        }
        guard hovering else { return .clear }
        return DS.tabHoverFill(scheme)
    }
}
