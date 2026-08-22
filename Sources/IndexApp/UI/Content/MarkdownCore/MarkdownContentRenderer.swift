import SwiftUI
import MarkdownUI

// MARK: - Markdown 内容渲染器（卡片缩略图）
//
// 用 MarkdownUI 渲染完整 GFM（标题/列表/表格/代码块/链接/图片/引用）。
// 输入是 shot + store，输出 AnyView（协议要求）。

struct MarkdownContentRenderer: ContentRenderer {
    let kind: ContentKind = .markdown

    @MainActor
    func render(shot: Shot, height: CGFloat, store: ShotStore, isHovering: Bool) -> AnyView {
        // 取 Markdown 源码
        let source: String
        if let shotID = shot.id,
           let content = try? store.content(for: shotID),
           let contentID = content.id,
           let md = try? store.markdownContent(for: contentID) {
            source = md.source
        } else {
            // 兜底：没有存储的 Markdown 就现场生成
            source = MarkdownGenerator.generate(for: shot)
        }

        return AnyView(
            ScrollView(.vertical, showsIndicators: false) {
                Markdown(source)
                    .markdownTheme(.gitHub)
                    .padding(10)
            }
        )
    }
}
