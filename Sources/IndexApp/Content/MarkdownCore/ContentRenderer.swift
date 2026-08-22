import SwiftUI

// MARK: - 内容渲染器
//
// 卡片中间内容区从"固定渲染图片"变成"按 ContentKind 分发到对应渲染器"。
// 每种内容类型一个渲染器实现，互不依赖。
//
// 设计原则：
//   · 渲染器是纯 UI 组件，不碰数据库、不碰剪贴板
//   · 输入只有 shot + 布局参数，输出一个 SwiftUI View
//   · 注册表按 ContentKind 查找，找不到就退回图片渲染器（兜底）
//   · 新增内容类型 = 新增一个渲染器文件 + 注册一行，不改卡片框架

/// 内容渲染器协议。
///
/// 实现者负责把 `shot` 的中间内容区画出来。
/// 顶部 bar 和底部 caption 由卡片框架统一处理，渲染器只管中间。
protocol ContentRenderer: Sendable {
    /// 该渲染器处理的内容类型。
    var kind: ContentKind { get }

    /// 渲染中间内容区。
    /// - Parameters:
    ///   - shot: 截图记录（含 sha256、尺寸、OCR 文本等）
    ///   - height: 内容区高度（由卡片布局决定）
    ///   - store: 图片存储（取缩略图/原图路径）
    ///   - isHovering: 卡片是否悬停中（视差等交互效果需要）
    /// - Returns: 中间内容区的 SwiftUI 视图
    @MainActor
    func render(shot: Shot, height: CGFloat, store: ShotStore, isHovering: Bool) -> AnyView
}

// MARK: - 注册表

/// 按 ContentKind 查找渲染器。找不到时退回图片渲染器。
@MainActor
final class ContentRendererRegistry: Sendable {

    static let shared = ContentRendererRegistry()

    private var renderers: [ContentKind: any ContentRenderer] = [:]

    init() {
        // 默认：图片渲染器（兜底）
        register(ImageContentRenderer())
        register(MarkdownContentRenderer())
    }

    func register(_ renderer: any ContentRenderer) {
        renderers[renderer.kind] = renderer
    }

    /// 获取渲染器。未注册的类型退回图片渲染器。
    func renderer(for kind: ContentKind) -> any ContentRenderer {
        renderers[kind] ?? renderers[.image] ?? ImageContentRenderer()
    }
}

// MARK: - 默认图片渲染器

/// 图片渲染器：保持现有行为（CachedImage 缩略图 + 视差）。
struct ImageContentRenderer: ContentRenderer {
    let kind: ContentKind = .image

    @MainActor
    func render(shot: Shot, height: CGFloat, store: ShotStore, isHovering: Bool) -> AnyView {
        AnyView(
            CachedImage(url: store.thumbnailURL(for: shot), key: shot.sha256)
                .parallaxThumbnail(isEnabled: isHovering)
        )
    }
}
