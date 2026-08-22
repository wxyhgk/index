import SwiftUI
import MarkdownEngine
import MarkdownEngineLatex

// MARK: - Markdown 编辑面（共享组件）
//
// NativeTextViewWrapper + SwiftMathBridge 配置的唯一定义处。
// QuickNote 和 MarkdownEditor 都消费它，换公式引擎只改这一处。

struct MarkdownEditorSurface: View {
    @Binding var text: String

    var body: some View {
        NativeTextViewWrapper(
            text: $text,
            configuration: {
                var config = MarkdownEditorConfiguration.default
                config.services.latex = SwiftMathBridge()
                return config
            }()
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
