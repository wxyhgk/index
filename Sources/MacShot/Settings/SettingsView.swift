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

            Section("识别") {
                Toggle("自动识别截图中的文字", isOn: $settings.runOCR)
                Text("在后台运行，识别结果进入全文索引，可以直接搜截图里的字。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
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
                    NSWorkspace.shared.activateFileViewerSelecting([store.rootDirectory])
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
