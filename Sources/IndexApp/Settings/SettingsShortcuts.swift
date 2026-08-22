import SwiftUI

struct ShortcutSettings: View {
    @ObservedObject var settings: AppSettings
    private let recorderSize = CGSize(width: 110, height: 22)

    var body: some View {
        SettingsPage {
            // 全局快捷键：大卡片（6 行 recorder）
            SettingsCard("全局快捷键", icon: "command") {
                shortcutRow("截图", $settings.shortcuts.captureShortcut)
                shortcutRow("延时截图", $settings.shortcuts.delayedCaptureShortcut)
                shortcutRow("录屏", $settings.shortcuts.recordingShortcut)
                shortcutRow("滚动截图", $settings.shortcuts.scrollCaptureShortcut)
                shortcutRow("打开图库", $settings.shortcuts.galleryShortcut)
                shortcutRow("3D 分子钉图", $settings.shortcuts.moleculePinShortcut)
                HStack {
                    Spacer()
                    Button("恢复默认") { settings.resetShortcuts() }
                        .controlSize(.mini)
                }
            }

            // 只读按键：小卡片并排
            ToggleCardGrid {
                MiniCard("标注工具", icon: "pencil.tip") {
                    ForEach(AnnotationTool.shortcuts, id: \.keyCode) { s in
                        keyRow(s.label, s.toolName)
                    }
                }

                MiniCard("其它按键", icon: "keyboard") {
                    keyRow("⌘Z", "撤销")
                    keyRow("⌘C", "复制")
                    keyRow("⇧C", "取字")
                    keyRow("⏎", "确定")
                    keyRow("⎋", "取消")
                    keyRow("右键", "退出")
                }

                MiniCard("钉图", icon: "pin") {
                    keyRow("⌘T", "穿透")
                    keyRow("滚轮", "缩放")
                    keyRow("⌘滚轮", "透明度")
                    keyRow("双击", "复制")
                }
            }
        }
    }

    private func shortcutRow(_ label: String, _ shortcut: Binding<KeyboardShortcut>) -> some View {
        HStack {
            Text(label).font(.system(size: DS.font12))
            Spacer()
            ShortcutRecorder(shortcut: shortcut)
                .frame(width: recorderSize.width, height: recorderSize.height)
        }
    }

    private func keyRow(_ key: String, _ desc: String) -> some View {
        HStack {
            Text(key).font(.system(size: DS.font12, design: .monospaced))
            Spacer()
            Text(desc).font(.system(size: DS.font11)).foregroundStyle(.secondary)
        }
    }
}
