import SwiftUI

// MARK: - 快捷键

struct ShortcutSettings: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section("全局快捷键") {
                LabeledContent("截图") {
                    ShortcutRecorder(shortcut: $settings.shortcuts.captureShortcut)
                        .frame(width: 130, height: 24)
                }
                LabeledContent("延时截图") {
                    ShortcutRecorder(shortcut: $settings.shortcuts.delayedCaptureShortcut)
                        .frame(width: 130, height: 24)
                }
                LabeledContent("录屏") {
                    ShortcutRecorder(shortcut: $settings.shortcuts.recordingShortcut)
                        .frame(width: 130, height: 24)
                }
                LabeledContent("滚动截图") {
                    ShortcutRecorder(shortcut: $settings.shortcuts.scrollCaptureShortcut)
                        .frame(width: 130, height: 24)
                }
                LabeledContent("打开图库") {
                    ShortcutRecorder(shortcut: $settings.shortcuts.galleryShortcut)
                        .frame(width: 130, height: 24)
                }
                LabeledContent("3D 分子钉图") {
                    ShortcutRecorder(shortcut: $settings.shortcuts.moleculePinShortcut)
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
                shortcutRow("⇧C", "取字：识别选区内全部文字并复制到剪贴板")
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
