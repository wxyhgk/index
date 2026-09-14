import SwiftUI
import AppKit
import MarkdownEngine
import MarkdownEngineLatex

// MARK: - Markdown 编辑面（共享组件）
//
// NativeTextViewWrapper + SwiftMathBridge 配置的唯一定义处。
// QuickNote 和 MarkdownEditor 都消费它，换公式引擎只改这一处。

struct MarkdownEditorSurface: View {
    @Binding var text: String
    var imageProvider: (any EmbeddedImageProvider)? = nil

    var body: some View {
        NativeTextViewWrapper(
            text: $text,
            configuration: {
                var config = MarkdownEditorConfiguration.default
                config.services.latex = SwiftMathBridge()
                if let imageProvider {
                    config.services.images = imageProvider
                }
                return config
            }()
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SmartQuotesOff())
    }
}

// swift-markdown-engine 在 makeNSView 中硬编码 isAutomaticQuoteSubstitutionEnabled = true，
// 导致输入英文直引号被替换为弯引号。此 helper 在 view 加入 window 后关闭该行为。
private struct SmartQuotesOff: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { [weak nsView] in
            guard let nsView, let window = nsView.window,
                  let contentView = window.contentView else { return }
            if let tv = Self.findTextView(in: contentView) {
                tv.isAutomaticQuoteSubstitutionEnabled = false
            }
        }
    }

    private static func findTextView(in view: NSView) -> NSTextView? {
        for sub in view.subviews {
            if let tv = sub as? NSTextView { return tv }
            if let found = findTextView(in: sub) { return found }
        }
        return nil
    }
}
