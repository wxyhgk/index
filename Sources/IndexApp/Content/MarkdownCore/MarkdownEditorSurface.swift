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
// 且 updateAutocorrectSettings 会在光标离开 code/LaTeX/link 区域时设回 true。
// 此 helper 通过 KVO 持续维持 false，只作用于 NSScrollView.documentView 子树（排除 field editor）。
private struct SmartQuotesOff: NSViewRepresentable {
    final class Coordinator {
        var kvoObservation: NSKeyValueObservation?
        weak var textView: NSTextView?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { [weak nsView, weak coordinator = context.coordinator] in
            guard let nsView, let coordinator,
                  let window = nsView.window,
                  let contentView = window.contentView else { return }
            // 只找 NSScrollView 的 documentView 子树，排除 field editor
            guard let tv = Self.findEditorTextView(in: contentView) else { return }
            guard tv !== coordinator.textView else { return }
            // 切换 textView：移除旧 KVO，建立新 KVO
            coordinator.kvoObservation?.invalidate()
            coordinator.textView = tv
            tv.isAutomaticQuoteSubstitutionEnabled = false
            coordinator.kvoObservation = tv.observe(
                \.isAutomaticQuoteSubstitutionEnabled, options: [.new]
            ) { [weak tv] _, _ in
                tv?.isAutomaticQuoteSubstitutionEnabled = false
            }
        }
    }

    func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.kvoObservation?.invalidate()
        coordinator.textView = nil
    }

    /// 只找 NSScrollView → documentView → 子树中的第一个 NSTextView。
    /// 排除 window field editor（它是 contentView 的直接子级，不在 scrollView 内）。
    private static func findEditorTextView(in view: NSView) -> NSTextView? {
        for sub in view.subviews {
            if let scrollView = sub as? NSScrollView,
               let docView = scrollView.documentView {
                return findTextView(in: docView)
            }
            if let found = findEditorTextView(in: sub) { return found }
        }
        return nil
    }

    private static func findTextView(in view: NSView) -> NSTextView? {
        if let tv = view as? NSTextView { return tv }
        for sub in view.subviews {
            if let found = findTextView(in: sub) { return found }
        }
        return nil
    }
}
