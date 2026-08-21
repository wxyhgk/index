import CoreGraphics
import Foundation

/// 标注撤销/重做操作栈。
///
/// 从 `AnnotationState` 拆出：栈本身是纯数据 + 出入栈规则，不依赖图层存储，
/// 可以单独单测。状态机持有一个实例，撤销/重做时由状态机自己执行真正的
/// 「倒回去/重放」（revert/apply），再把记录交还栈里。
///
/// 不变量：**所有可撤销的改动必须经 `record`** —— 唯一写入口。
/// 新动作发生后，之前撤销掉的分支不可再重做（redoStack 清空）。
///
/// 栈不是 ObservableObject：栈的每次变化都伴随一次图层变化（状态机的
/// willSet 会发 objectWillChange）；状态机在 undo/redo 里再显式补一次
/// publishChange，保证工具条 canUndo/canRedo 的刷新不丢。
@MainActor
final class AnnotationHistory {

    /// 一次可逆的改动。撤销/重做只回放这些记录，绝不重新计算 ——
    /// 马赛克贴片直接存进记录里，撤销时原样恢复，不依赖任何外部像素源的生命周期。
    enum Mutation {
        /// 撤销 = 删掉它（连带贴片）；重做 = 连贴片一起加回来。
        case add(Layer, preview: CGImage?)
        /// 撤销 = 按原位插回、恢复贴片。
        case remove(Layer, index: Int, preview: CGImage?)
        case move(id: UUID, from: LRect, to: LRect, oldPreview: CGImage?, newPreview: CGImage?)
        /// 颜色 / 粗细 / 文字内容都算 style：整层快照替换，简单且不会漏字段。
        case style(id: UUID, before: Layer, after: Layer)
    }

    private(set) var undoStack: [Mutation] = []
    private(set) var redoStack: [Mutation] = []

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    /// `setText` 连续针对哪一层在合并撤销记录。任何其它记录入栈都会打断合并。
    private var coalescingTextID: UUID?

    /// 所有写路径的唯一入口：新动作发生后，之前撤销掉的分支就不可再重做。
    func record(_ mutation: Mutation) {
        coalescingTextID = nil
        undoStack.append(mutation)
        redoStack.removeAll()
    }

    /// 记一条 style 改动；针对同一层的连续 style 合并成一条记录：
    /// 撤销一次回到编辑前，而不是逐键回退出几十条历史。
    func recordStyle(id: UUID, before: Layer, after: Layer) {
        if coalescingTextID == id,
           case .style(let sid, let original, _)? = undoStack.last, sid == id {
            undoStack[undoStack.count - 1] = .style(id: id, before: original, after: after)
            return
        }
        record(.style(id: id, before: before, after: after))
        coalescingTextID = id
    }

    /// 弹出最顶的撤销记录。调用方执行真正的倒回去，再经 `pushRedo` 交还。
    func popUndo() -> Mutation? {
        guard let mutation = undoStack.popLast() else { return nil }
        coalescingTextID = nil
        return mutation
    }

    func pushRedo(_ mutation: Mutation) {
        redoStack.append(mutation)
    }

    /// 弹出最顶的重做记录。调用方执行真正的重放，再经 `pushUndo` 交还。
    func popRedo() -> Mutation? {
        guard let mutation = redoStack.popLast() else { return nil }
        coalescingTextID = nil
        return mutation
    }

    func pushUndo(_ mutation: Mutation) {
        undoStack.append(mutation)
    }

    /// 打断当前的文字合并（换了选中对象后，文字替换要重新开一条记录）。
    func breakCoalescing() {
        coalescingTextID = nil
    }

    /// 全部清空（clear / load 时）。
    func reset() {
        undoStack.removeAll()
        redoStack.removeAll()
        coalescingTextID = nil
    }
}