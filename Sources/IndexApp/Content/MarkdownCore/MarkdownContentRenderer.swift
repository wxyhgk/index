import SwiftUI

// MARK: - Markdown 内容渲染器（卡片缩略图）
//
// 网格卡片不是文档阅读器。完整 MarkdownUI AST、主题和图片布局放在单窗口编辑器；
// 虚拟化网格只画缓存后的纯文本预览，快速滚动时不重复查三张表和解析整篇 GFM。

@MainActor
final class MarkdownPreviewCache {
    static let shared = MarkdownPreviewCache()
    private var sources: [Int64: String] = [:]

    func source(for shot: Shot, store: ShotStore) -> String {
        guard let id = shot.id else { return MarkdownGenerator.generate(for: shot) }
        if let cached = sources[id] { return cached }
        let source = store.markdownSource(for: shot) ?? MarkdownGenerator.generate(for: shot)
        sources[id] = source
        return source
    }

    func update(_ source: String, shotID: Int64?) {
        guard let shotID else { return }
        sources[shotID] = source
    }
}

struct MarkdownContentRenderer: ContentRenderer {
    let kind: ContentKind = .markdown

    @MainActor
    func render(shot: Shot, height: CGFloat, store: ShotStore, isHovering: Bool) -> AnyView {
        let source = MarkdownPreviewCache.shared.source(for: shot, store: store)

        return AnyView(
            Text(source)
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(.primary)
                .lineLimit(max(4, Int(height / 18)))
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, minHeight: height, alignment: .topLeading)
                .padding(10)
                .clipped()
        )
    }
}
