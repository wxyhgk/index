import SwiftUI
import AppKit
import MarkdownEngine
import MarkdownEngineLatex

// MARK: - Markdown 编辑器（Typora 风格）
//
// 基于 swift-markdown-engine（nodes-app）的 NativeTextViewWrapper：
//   · 所见即所得：输入 # 实时变标题、** 变粗体、- 变列表
//   · 完整 GFM：表格/代码块高亮/链接/图片/引用/任务复选框
//   · 原生 TextKit 2，macOS 14+，零外部依赖
//
// 编辑器直接绑定 Markdown 源码（String），
// 保存时把 Binding 里的源码写回数据库。

// MARK: - 编辑器视图（SwiftUI）

struct MarkdownEditorView: View {
    @State var source: String
    let title: String
    let onSave: (String) -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // 顶部栏
            HStack {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button("保存") {
                    onSave(source)
                }
                .keyboardShortcut("s", modifiers: .command)
                Button("关闭") { onClose() }
                .keyboardShortcut("w", modifiers: .command)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)
            .overlay(Divider(), alignment: .bottom)

            // 编辑区（共享组件：MarkdownEngine 所见即所得 + SwiftMath 公式渲染）
            MarkdownEditorSurface(text: $source)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}

// MARK: - 编辑器窗口

@MainActor
final class MarkdownEditorWindowController {

    private var window: NSWindow?

    static let shared = MarkdownEditorWindowController()

    /// 打开 Markdown 编辑器窗口。
    func show(
        title: String,
        source: String,
        onSave: @escaping (String) -> Void
    ) {
        close()

        let view = MarkdownEditorView(
            source: source,
            title: title,
            onSave: { newSource in
                onSave(newSource)
                self.close()
            },
            onClose: { self.close() }
        )

        let hostingView = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hostingView)
        window.title = "Markdown 编辑器"
        window.styleMask = [.titled, .closable, .resizable]
        window.setContentSize(NSSize(width: 700, height: 500))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }

    func close() {
        window?.close()
        window = nil
    }
}
