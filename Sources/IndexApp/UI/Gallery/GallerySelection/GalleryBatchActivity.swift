import Combine
import Foundation

/// 图库跨页批量复制/导出的全局单飞状态。
///
/// 同一批像素重活不能从详情栏、右键菜单和快捷键同时启动多份。状态独立于任一 View，
/// 所以面板重建或右键菜单消失都不会丢掉进度；取消只作用于当前 token，迟到任务不能
/// 误伤下一次操作。
@MainActor
final class GalleryBatchActivity: ObservableObject {

    enum Kind: Equatable {
        case copy
        case export

        var title: String {
            switch self {
            case .copy: return "正在准备复制"
            case .export: return "正在导出"
            }
        }
    }

    struct State: Equatable {
        let token: UUID
        let kind: Kind
        let total: Int
        var processed: Int
        var isCancelling: Bool

        var progress: Double {
            guard total > 0 else { return 0 }
            return min(1, Double(processed) / Double(total))
        }
    }

    @Published private(set) var state: State?
    private var cancelHandler: (() -> Void)?

    var isBusy: Bool { state != nil }

    @discardableResult
    func begin(kind: Kind, total: Int) -> UUID? {
        guard state == nil, total > 0 else { return nil }
        let token = UUID()
        state = State(token: token, kind: kind, total: total, processed: 0, isCancelling: false)
        cancelHandler = nil
        return token
    }

    func attachCancellation(token: UUID, _ handler: @escaping () -> Void) {
        guard let current = state, current.token == token else {
            handler()
            return
        }
        if current.isCancelling {
            handler()
        } else {
            cancelHandler = handler
        }
    }

    func update(token: UUID, processed: Int) {
        guard var current = state, current.token == token else { return }
        current.processed = min(max(processed, current.processed), current.total)
        state = current
    }

    func cancel() {
        guard var current = state, !current.isCancelling else { return }
        current.isCancelling = true
        state = current
        let handler = cancelHandler
        cancelHandler = nil
        handler?()
    }

    func finish(token: UUID) {
        guard state?.token == token else { return }
        cancelHandler = nil
        state = nil
    }
}
