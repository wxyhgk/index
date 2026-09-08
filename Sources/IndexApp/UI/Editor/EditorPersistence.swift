import CoreGraphics
import Foundation

/// 编辑会话真正需要的最小持久化边界。
///
/// `ShotStore` 的写接口为了兼容既有调用方以 Optional 表达失败；编辑器不能继续
/// 吞掉这个结果，因为它必须据此决定能否推进“已保存基线”和离开当前会话。
@MainActor
protocol EditorPersistence: AnyObject {
    func originalImage(for shot: Shot) -> CGImage?
    func revisions(for shot: Shot) -> [Revision]
    func appendEditorRevision(
        shot: Shot,
        layers: Layers<ImageSpace>,
        note: String?
    ) throws -> Revision
}

enum EditorPersistenceError: LocalizedError {
    case revisionWriteFailed

    var errorDescription: String? {
        switch self {
        case .revisionWriteFailed:
            return "无法把标注写入修订历史。当前改动仍保留在编辑器中。"
        }
    }
}

extension ShotStore: EditorPersistence {
    func appendEditorRevision(
        shot: Shot,
        layers: Layers<ImageSpace>,
        note: String?
    ) throws -> Revision {
        guard let revision = appendRevision(shot: shot, layers: layers, note: note) else {
            throw EditorPersistenceError.revisionWriteFailed
        }
        return revision
    }
}
