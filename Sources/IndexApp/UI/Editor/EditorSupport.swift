import SwiftUI

/// 画布 NSView 的引用容器。LayerCanvas 是 NSViewRepresentable，NSView 实例
/// 只能在 makeNSView 里拿到 —— 用闭包回传存到这里，⌘C / 悬停让位才能摸到它。
final class CanvasHolder {
    var view: CanvasView?
}

/// 稳定外壳与当前编辑会话之间唯一的一条命令通道。
///
/// Filmstrip 已经移到会话 `.id` 之外，但切图仍必须保持原来的“先落库再换图”顺序。
/// relay 只暂存当前会话的 flush 闭包；shot ID 校验防止旧会话的 onDisappear 清掉
/// 刚安装的新会话。
@MainActor
final class EditorSessionRelay: ObservableObject {
    private var shotID: Int64?
    private var flushAction: (() -> Bool)?

    func install(shotID: Int64?, flush: @escaping () -> Bool) {
        self.shotID = shotID
        flushAction = flush
    }

    func flush(shotID: Int64?) -> Bool {
        // 编辑模式刚切入、SwiftUI 会话尚未 onAppear 时还没有任何内存画布可保存；
        // 这种“无活动会话”应视为安全成功，避免红色关闭被永久卡住。
        guard let flushAction else { return true }
        // 已有活动会话却收到另一张图的请求，说明模式切换尚未完成，保守阻止离开。
        guard self.shotID == shotID else { return false }
        return flushAction()
    }

    func remove(shotID: Int64?) {
        guard self.shotID == shotID else { return }
        self.shotID = nil
        flushAction = nil
    }
}

/// 编辑模式的稳定外壳。
///
/// 只有真正依赖 `shot` 的编辑会话按 ID 重建；Filmstrip 留在外面保持自己的
/// 横向滚动位置。此前 `.id(shot.id)` 套在整个 `EditorView` 上，点一张缩略图会把
/// Filmstrip 一起销毁，再从空数组加载并把当前项强制居中，看起来就像其它图片消失。
struct EditorModeView: View {
    let shot: Shot
    let styleStore: any AnnotationStylePreferences
    /// 由图库窗口持有，确保红色关闭按钮和编辑器导航询问的是同一个保存会话。
    let sessionRelay: EditorSessionRelay
    @Environment(\.galleryPageCommands) private var pageCommands

    var body: some View {
        VStack(spacing: 0) {
            EditorView(
                shot: shot,
                sessionRelay: sessionRelay,
                styleStore: styleStore,
                pageCommands: pageCommands
            )
                .id(shot.id)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            EditorFilmstrip(
                currentShotID: shot.id,
                onSelect: switchEditor
            )
            .equatable()
        }
        .frame(minWidth: 900, minHeight: 620)
    }

    private func switchEditor(to target: Shot) {
        guard target.id != shot.id else { return }
        guard sessionRelay.flush(shotID: shot.id) else { return }
        pageCommands.openEditor(shotID: target.id)
    }
}
