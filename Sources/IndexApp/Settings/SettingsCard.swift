import SwiftUI

// MARK: - 设置页组件
//
// 仿插件页：小卡片网格。每个设置项一张独立小卡片，并排排列。

// MARK: Toggle 小卡片（图标 + 标签 + 开关，一行）

struct ToggleCard: View {
    let label: String
    let icon: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: DS.s2) {
            Image(systemName: icon)
                .font(.system(size: DS.font12, weight: .medium))
                .foregroundStyle(isOn ? DS.accent : .secondary)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: DS.radiusSmall, style: .continuous)
                        .fill(isOn ? DS.accentFillSelected : DS.iconPlaceholderFill)
                )

            Text(label)
                .font(.system(size: DS.font13, weight: .medium))
                .lineLimit(1)

            Spacer(minLength: DS.s2)

            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
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
    }
}

// MARK: 大卡片（带输入框/滑块/Picker 的复杂配置）

struct SettingsCard<Content: View>: View {
    let title: String
    var icon: String? = nil
    @ViewBuilder let content: Content

    init(_ title: String, icon: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.s2) {
            HStack(spacing: DS.s2) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: DS.font13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 18)
                }
                Text(title)
                    .font(.system(size: DS.font14, weight: .semibold))
            }
            content
        }
        .padding(DS.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous)
                .fill(DS.panelFill(.resting))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous)
                .strokeBorder(DS.borderSubtle, lineWidth: DS.hairline)
        )
    }
}

// MARK: 设置行（大卡片内部用）

struct SettingsRow<Content: View>: View {
    let label: String
    var icon: String? = nil
    @ViewBuilder let content: Content

    init(_ label: String, icon: String? = nil, @ViewBuilder content: () -> Content) {
        self.label = label
        self.icon = icon
        self.content = content()
    }

    var body: some View {
        HStack(spacing: DS.s2) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: DS.font12))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
            }
            Text(label)
                .font(.system(size: DS.font13))
            Spacer(minLength: DS.s2)
            content
        }
    }
}

// MARK: 设置页容器
//
// 左对齐 + 限宽。小卡片用 ToggleCardGrid 并排，大卡片占满一行。

struct SettingsPage<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.s3) {
                content
            }
            .padding(DS.s3)
        }
        .scrollIndicators(.hidden)
    }
}

// MARK: 小卡片网格（ToggleCard / MiniCard 并排）

struct ToggleCardGrid<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 220, maximum: 320), spacing: DS.s3)],
            spacing: DS.s3
        ) {
            content
        }
    }
}

// MARK: 小卡片（图标 + 标题 + 任意内容，和 ToggleCard 同尺寸）

struct MiniCard<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: Content

    init(_ title: String, icon: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.s2) {
            HStack(spacing: DS.s2) {
                Image(systemName: icon)
                    .font(.system(size: DS.font12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .background(
                        RoundedRectangle(cornerRadius: DS.radiusSmall, style: .continuous)
                            .fill(DS.iconPlaceholderFill)
                    )
                Text(title)
                    .font(.system(size: DS.font13, weight: .medium))
                    .lineLimit(1)
            }
            content
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
    }
}
