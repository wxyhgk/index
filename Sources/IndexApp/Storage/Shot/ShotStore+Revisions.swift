import Foundation
import CoreGraphics

// MARK: - 修订链 / 缩略图重画
//
// 从 `ShotStore.swift` 拆出：修订的读取与追加（同事务父子链），
// 以及修订保存后的缩略图重画链。渲染器与缓存作废回调是 App 层注入的
// 闭包（存储属性在主文件）—— 依赖方向不许 Storage 认识 Render（ARCHITECTURE §1）。

extension ShotStore {
    // MARK: - 修订

    func revisions(for shot: Shot) -> [Revision] {
        guard let id = shot.id else { return [] }
        return (try? revisionRepository.revisions(shotID: id)) ?? []
    }

    func latestRevision(for shot: Shot) -> Revision? {
        guard let id = shot.id else { return nil }
        return try? revisionRepository.latestRevision(shotID: id)
    }

    /// 追加一个新修订。永远不覆盖旧记录 —— 这就是「无限记录」的实现方式。
    ///
    /// 「读父节点」和「写新节点」必须在**同一个事务**里：分成两次的话，
    /// 图库编辑器和钉图窗口同时提交会拿到相同的 parentID，产生非预期的分叉，
    /// 而下游（latestRevision / EditorView）全部假设修订链是线性的。
    @discardableResult
    func appendRevision(shot: Shot, layers: Layers<ImageSpace>, note: String?) -> Revision? {
        guard let shotID = shot.id else { return nil }

        do {
            let saved = try revisionRepository.append(
                shotID: shotID,
                layers: layers.persisted,
                note: note
            )
            // 缩略图是按**原图**生成、以 sha256 命名的，而 sha 只认原图字节 ——
            // 加多少标注它都不变。不在这里重画的话，图库网格会一直显示没有标注的
            // 那一版（编辑完返回图库「图片没更新」就是这么来的）。
            refreshThumbnail(for: shot, layers: layers)

            // 修订不在 shots 数组里，落库不会自己触发发布 ——
            // 图库网格（缩略图刚换过）、详情栏（历史版本 / 已打码判定）靠这次发布重查。
            objectWillChange.send()
            return saved
        } catch {
            // 此前是 try?，写失败仍返回一个 id 为 nil 的 Revision，调用方无从分辨。
            NSLog("[Index] 追加修订失败: \(error)")
            return nil
        }
    }

    // MARK: - 缩略图重画

    /// 按当前图层重画缩略图并覆盖写盘。
    ///
    /// 失败一律静默：缩略图是派生数据，画不出来最多是显示旧的一版，
    /// 不该让一次修订保存失败。
    private func refreshThumbnail(for shot: Shot, layers: Layers<ImageSpace>) {
        guard let render = revisionThumbnailRenderer,
              let base = originalImage(for: shot) else { return }

        // ⚠️ **绝不在主线程上跑**。这条链是「全分辨率渲染 → 缩放 → JPEG 编码 → 写盘」，
        // 一张 3456×1986 的截图跑一趟是上百毫秒级；而它挂在自动保存后面，
        // 于是编辑时每隔一秒多就把主线程堵一次 —— 表现为「点按钮有延迟」。
        //
        // CGImage 与 LayerRenderer / ImageCodec 都不是 MainActor 隔离的，
        // 渲染和编码可以整段搬到后台；回主线程的只有一次缓存作废。
        let url = thumbnailURL(for: shot)
        let payload = ThumbnailJob(base: base, layers: layers, render: render, url: url)
        // 作废回调**先取出来**，不要在后台回调里走 `ShotStore.shared` ——
        // 那样非单例的实例（比如测试用的独立库）通知不到自己的订阅方。
        let invalidate = thumbnailInvalidator

        Task.detached(priority: .utility) {
            guard let jpg = payload.encode() else { return }
            try? jpg.write(to: payload.url, options: .atomic)
            await MainActor.run {
                // 文件覆盖了还不够：内存缓存的键是 sha256，而 sha 没变 ——
                // 不主动作废的话界面会继续用缓存里那张旧图。
                invalidate?(shot)
            }
        }
    }

    /// 后台重画缩略图要带走的一整套材料。
    ///
    /// 打包成一个 `@unchecked Sendable` 的值而不是在 `Task.detached` 里逐个捕获：
    /// 这些东西（CGImage、图层数组、渲染闭包）造好之后**没有人再改它们**，
    /// 是一次所有权转移而不是共享。用一个类型把这件事讲明白，
    /// 好过在捕获处埋一串静默的 unchecked。
    private struct ThumbnailJob: @unchecked Sendable {
        let base: CGImage
        let layers: Layers<ImageSpace>
        let render: (CGImage, Layers<ImageSpace>) -> CGImage
        let url: URL

        func encode() -> Data? {
            let composed = render(base, layers)
            guard let thumb = ImageCodec.resized(composed, maxDimension: 640) else { return nil }
            return ImageCodec.jpegData(from: thumb)
        }
    }
}
