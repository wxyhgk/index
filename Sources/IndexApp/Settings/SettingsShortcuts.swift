import SwiftUI

struct ShortcutSettings: View {
    @ObservedObject var settings: AppSettings
    private let recorderSize = CGSize(width: 110, height: 22)

    private struct ShortcutRow: Identifiable {
        let id: String
        let label: String
        let keyPath: WritableKeyPath<ShortcutPrefs, KeyboardShortcut>
    }

    private static let captureShortcuts = [
        ShortcutRow(id: "capture", label: "截图", keyPath: \.captureShortcut),
        ShortcutRow(id: "delayed-capture", label: "延时截图", keyPath: \.delayedCaptureShortcut),
        ShortcutRow(id: "recording", label: "录屏", keyPath: \.recordingShortcut),
        ShortcutRow(id: "scroll-capture", label: "滚动截图", keyPath: \.scrollCaptureShortcut),
    ]

    private static let workspaceShortcuts = [
        ShortcutRow(id: "gallery", label: "打开图库", keyPath: \.galleryShortcut),
        ShortcutRow(id: "clipboard", label: "剪切板历史", keyPath: \.clipboardHistoryShortcut),
        ShortcutRow(id: "search", label: "输入即检索", keyPath: \.searchPanelShortcut),
        ShortcutRow(id: "quick-note", label: "新建便签", keyPath: \.quickNoteShortcut),
        ShortcutRow(id: "quick-note-resume", label: "继续上次便签", keyPath: \.quickNoteResumeShortcut),
        ShortcutRow(id: "agent", label: "AI Agent", keyPath: \.agentShortcut),
        ShortcutRow(id: "molecule-pin", label: "3D 分子钉图", keyPath: \.moleculePinShortcut),
    ]

    var body: some View {
        SettingsPage {
            SettingsCard("捕获快捷键", icon: "camera") {
                ForEach(Self.captureShortcuts) { row in
                    shortcutRow(row.label, binding(for: row.keyPath))
                }
            }

            SettingsCard("工作区快捷键", icon: "command") {
                ForEach(Self.workspaceShortcuts) { row in
                    shortcutRow(row.label, binding(for: row.keyPath))
                }
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

                // 选区阶段才生效的裸键。P / R 在标注阶段会切换到像素化 / 矩形工具，
                // 两套规则靠 phase 分开，所以必须单独列出来，不能混进上面的工具清单。
                MiniCard("选区", icon: "rectangle.dashed") {
                    keyRow("R / ⇧R", "复用上次区域")
                    keyRow("P", "多边形选区")
                    keyRow("⏎", "闭合多边形")
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

    private func binding(
        for keyPath: WritableKeyPath<ShortcutPrefs, KeyboardShortcut>
    ) -> Binding<KeyboardShortcut> {
        Binding(
            get: { settings.shortcuts[keyPath: keyPath] },
            set: { settings.shortcuts[keyPath: keyPath] = $0 }
        )
    }

    private func keyRow(_ key: String, _ desc: String) -> some View {
        HStack {
            Text(key).font(.system(size: DS.font12, design: .monospaced))
            Spacer()
            Text(desc).font(.system(size: DS.font11)).foregroundStyle(.secondary)
        }
    }
}
