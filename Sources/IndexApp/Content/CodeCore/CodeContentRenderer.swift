import SwiftUI

struct CodePreview: Equatable, Sendable {
    static let characterLimit = 8_192

    let text: String
    let language: String?

    init(content: ContentCode?) {
        text = String((content?.text ?? "").prefix(Self.characterLimit))
        language = content?.language
    }
}

@MainActor
final class CodePreviewCache {
    static let shared = CodePreviewCache()

    private final class Box {
        let preview: CodePreview
        init(_ preview: CodePreview) { self.preview = preview }
    }

    private let cache = NSCache<NSNumber, Box>()

    init() {
        cache.countLimit = 512
        cache.totalCostLimit = 4 * 1_024 * 1_024
    }

    func preview(for shot: Shot, store: any ShotReading) -> CodePreview {
        guard let shotID = shot.id else { return CodePreview(content: nil) }
        let key = NSNumber(value: shotID)
        if let cached = cache.object(forKey: key) { return cached.preview }
        let preview = CodePreview(content: store.codeContent(for: shot))
        cache.setObject(Box(preview), forKey: key, cost: preview.text.utf8.count)
        return preview
    }

    func update(text: String, language: String?, shotID: Int64?) {
        guard let shotID else { return }
        let content = ContentCode(
            contentID: shotID,
            language: ContentCode.normalizedLanguage(language),
            text: text
        )
        let preview = CodePreview(content: content)
        cache.setObject(Box(preview), forKey: NSNumber(value: shotID), cost: preview.text.utf8.count)
    }
}

/// 虚拟化网格只排有限长度的纯文本，不做语法 AST、高亮或逐行视图。
struct CodeContentRenderer: ContentRenderer {
    let kind: ContentKind = .code

    @MainActor
    func render(shot: Shot, height: CGFloat, store: any ShotReading, isHovering: Bool) -> AnyView {
        let preview = CodePreviewCache.shared.preview(for: shot, store: store)
        return AnyView(
            ZStack(alignment: .topLeading) {
                Text(preview.text.isEmpty ? "在这里输入代码…" : preview.text)
                    .font(.system(size: DS.font12, design: .monospaced))
                    .foregroundStyle(preview.text.isEmpty ? Color.secondary : Color.primary)
                    .lineLimit(max(4, Int(height / 17)))
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, minHeight: height, alignment: .topLeading)
                    .padding(DS.s2)
            }
            .overlay(alignment: .bottomTrailing) {
                if let language = preview.language {
                    Text(CodeLanguage.displayName(for: language))
                        .font(.system(size: DS.font9, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, DS.s2)
                        .padding(.vertical, DS.s1)
                }
            }
            .clipped()
        )
    }
}
