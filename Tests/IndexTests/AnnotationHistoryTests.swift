import XCTest
@testable import IndexApp

/// 撤销/重做操作栈的纯规则单测：出入栈顺序、redo 分支清空、style 合并、reset。
///
/// 栈与图层存储分离后，这里只验证「栈规则」；回放动作（revert/apply）
/// 对图层的实际影响由状态机集成测试（AnnotationIMETests 等）覆盖。
@MainActor
final class AnnotationHistoryTests: XCTestCase {

    private func makeLayer(_ id: UUID, rect: LRect = LRect(x: 0, y: 0, w: 10, h: 10)) -> Layer {
        Layer(id: id, kind: .rect, rect: rect)
    }

    /// 模拟一次完整的撤销：弹出 → （状态机回放）→ 交还 redo 栈。
    private func undo(_ history: AnnotationHistory) {
        guard let mutation = history.popUndo() else {
            return XCTFail("undoStack 应为空")
        }
        history.pushRedo(mutation)
    }

    func testRecordClearsRedoBranch() {
        let history = AnnotationHistory()
        history.record(.add(makeLayer(UUID()), preview: nil))
        undo(history)
        XCTAssertTrue(history.canRedo)

        history.record(.add(makeLayer(UUID()), preview: nil))
        XCTAssertFalse(history.canRedo, "新动作应清空 redo 分支")
        XCTAssertTrue(history.canUndo)
    }

    func testPopOrderIsLIFO() {
        let history = AnnotationHistory()
        let a = UUID()
        let b = UUID()
        history.record(.add(makeLayer(a), preview: nil))
        history.record(.add(makeLayer(b), preview: nil))

        guard case .add(let top, _)? = history.popUndo() else {
            return XCTFail("栈顶应是 add 记录")
        }
        XCTAssertEqual(top.id, b, "LIFO：最后入栈的先出")
        guard case .add(let next, _)? = history.popUndo() else {
            return XCTFail("第二条应是 add 记录")
        }
        XCTAssertEqual(next.id, a)
    }

    func testConsecutiveStyleOnSameLayerCoalesces() {
        let history = AnnotationHistory()
        let id = UUID()
        let before = makeLayer(id)
        let mid = makeLayer(id, rect: LRect(x: 0, y: 0, w: 12, h: 10))
        let after = makeLayer(id, rect: LRect(x: 0, y: 0, w: 14, h: 10))

        history.recordStyle(id: id, before: before, after: mid)
        history.recordStyle(id: id, before: mid, after: after)
        XCTAssertEqual(history.undoStack.count, 1, "同一层连续 style 应合并成一条")

        guard case .style(_, let mergedBefore, let mergedAfter)? = history.popUndo() else {
            return XCTFail("合并后应是 style 记录")
        }
        XCTAssertEqual(mergedBefore.id, id)
        XCTAssertEqual(mergedBefore.rect.w, 10, "合并记录保留最早的 before 快照")
        XCTAssertEqual(mergedAfter.rect.w, 14, "合并记录保留最新的 after")
    }

    func testDifferentLayerBreaksCoalescing() {
        let history = AnnotationHistory()
        let a = UUID()
        let b = UUID()
        history.recordStyle(id: a, before: makeLayer(a), after: makeLayer(a, rect: LRect(x: 1, y: 0, w: 10, h: 10)))
        history.recordStyle(id: b, before: makeLayer(b), after: makeLayer(b, rect: LRect(x: 2, y: 0, w: 10, h: 10)))
        XCTAssertEqual(history.undoStack.count, 2, "换层应开新记录")
    }

    func testOtherRecordBreaksCoalescing() {
        let history = AnnotationHistory()
        let id = UUID()
        let before = makeLayer(id)
        let mid = makeLayer(id, rect: LRect(x: 0, y: 0, w: 12, h: 10))
        let after = makeLayer(id, rect: LRect(x: 0, y: 0, w: 14, h: 10))

        history.recordStyle(id: id, before: before, after: mid)
        history.record(.add(makeLayer(UUID()), preview: nil))
        history.recordStyle(id: id, before: mid, after: after)
        XCTAssertEqual(history.undoStack.count, 3, "中间夹一条 add 应打断合并")
    }

    func testBreakCoalescingStartsFreshRecord() {
        let history = AnnotationHistory()
        let id = UUID()
        let before = makeLayer(id)
        let mid = makeLayer(id, rect: LRect(x: 0, y: 0, w: 12, h: 10))
        let after = makeLayer(id, rect: LRect(x: 0, y: 0, w: 14, h: 10))

        history.recordStyle(id: id, before: before, after: mid)
        history.breakCoalescing()
        history.recordStyle(id: id, before: mid, after: after)
        XCTAssertEqual(history.undoStack.count, 2, "breakCoalescing 后同层 style 也要开新记录")
    }

    func testUndoBreaksCoalescing() {
        let history = AnnotationHistory()
        let id = UUID()
        let before = makeLayer(id)
        let mid = makeLayer(id, rect: LRect(x: 0, y: 0, w: 12, h: 10))
        let after = makeLayer(id, rect: LRect(x: 0, y: 0, w: 14, h: 10))

        history.recordStyle(id: id, before: before, after: mid)
        undo(history)
        history.recordStyle(id: id, before: mid, after: after)
        XCTAssertEqual(history.undoStack.count, 1, "撤销后同层 style 不再并入旧记录")
    }

    func testRedoRoundTrip() {
        let history = AnnotationHistory()
        let a = UUID()
        history.record(.add(makeLayer(a), preview: nil))
        undo(history)
        XCTAssertTrue(history.canRedo)

        guard let mutation = history.popRedo() else {
            return XCTFail("redo 栈不应为空")
        }
        guard case .add(let replayed, _) = mutation else {
            return XCTFail("redo 栈顶应是 add 记录")
        }
        history.pushUndo(mutation)
        XCTAssertEqual(replayed.id, a)
        XCTAssertTrue(history.canUndo)
        XCTAssertFalse(history.canRedo)
    }

    func testResetClearsEverything() {
        let history = AnnotationHistory()
        history.record(.add(makeLayer(UUID()), preview: nil))
        undo(history)
        history.reset()
        XCTAssertFalse(history.canUndo)
        XCTAssertFalse(history.canRedo)
    }
}