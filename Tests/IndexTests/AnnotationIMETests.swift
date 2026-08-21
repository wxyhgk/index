import XCTest
@testable import IndexApp
import AppKit
import CoreText

@MainActor
final class AnnotationIMETests: XCTestCase {

    // MARK: - IMECaretGeometry 字符级宽度（与 handleBounds 同源 CTLine）

    func testPrefixWidthMonotonicAndClamped() {
        let full = "ab中c"
        let fs: CGFloat = 24
        let w0 = IMECaretGeometry.prefixWidth(fullText: full, prefixLength: 0, fontSize: fs)
        let w1 = IMECaretGeometry.prefixWidth(fullText: full, prefixLength: 1, fontSize: fs)
        let w2 = IMECaretGeometry.prefixWidth(fullText: full, prefixLength: 2, fontSize: fs)
        let wAll = IMECaretGeometry.prefixWidth(fullText: full, prefixLength: 100, fontSize: fs)
        let wFull = IMECaretGeometry.prefixWidth(fullText: full, prefixLength: (full as NSString).length, fontSize: fs)
        XCTAssertEqual(w0, 0, accuracy: 0.01)
        XCTAssertGreaterThan(w1, w0)
        XCTAssertGreaterThan(w2, w1)
        XCTAssertEqual(wAll, wFull, accuracy: 0.01, "超界应截断到全长")
    }

    func testPrefixWidthMatchesHandleBoundsForPrefix() {
        // 与 Layer.handleBounds 的测量路径一致：同一字体、同一 CTLine 系数
        let text = "Hello中文"
        let fs: CGFloat = 28
        for len in 0...(text as NSString).length {
            let w = IMECaretGeometry.prefixWidth(fullText: text, prefixLength: len, fontSize: fs)
            // 独立用 CTLine 量同一前缀比对
            let prefix = (text as NSString).substring(to: len)
            let font = NSFont.systemFont(ofSize: fs, weight: .semibold)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: prefix, attributes: [.font: font]))
            let expected = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            XCTAssertEqual(w, expected, accuracy: 0.01, "len=\(len) 字符级宽度应与 CTLine 完全一致")
        }
    }

    func testLineHeightEmptyFallsBackToFontSize() {
        let hEmpty = IMECaretGeometry.lineHeight(for: "", fontSize: 20)
        XCTAssertEqual(hEmpty, 20, accuracy: 0.01)
        let hNonEmpty = IMECaretGeometry.lineHeight(for: "A", fontSize: 20)
        XCTAssertGreaterThan(hNonEmpty, 0)
        XCTAssertNotEqual(hNonEmpty, 0)
    }

    // MARK: - Overlay / Pin 视图坐标精度（含 bounds.height 翻转与 scale）

    func testOverlayViewRectFlipsYAndOffsetsByWidth() {
        let layerRect = CGRect(x: 10, y: 20, width: 0, height: 0)
        let boundsH: CGFloat = 800
        let fs: CGFloat = 24
        let full = "ab"
        let width = IMECaretGeometry.prefixWidth(fullText: full, prefixLength: 1, fontSize: fs)
        let h = IMECaretGeometry.lineHeight(for: full, fontSize: fs)
        let rect = IMECaretGeometry.overlayViewRect(layerRect: layerRect, fullText: full, fontSize: fs, prefixLength: 1, boundsHeight: boundsH)
        XCTAssertEqual(rect.origin.x, layerRect.origin.x + width, accuracy: 0.01)
        XCTAssertEqual(rect.origin.y, boundsH - layerRect.origin.y - h, accuracy: 0.01)
        XCTAssertEqual(rect.size.width, 8, accuracy: 0.01)
        XCTAssertEqual(rect.size.height, h + 6, accuracy: 0.01)
    }

    func testOverlayEmptyTextCaretAtAnchor() {
        let layerRect = CGRect(x: 50, y: 100, width: 0, height: 0)
        let rect = IMECaretGeometry.overlayViewRect(layerRect: layerRect, fullText: "", fontSize: 18, prefixLength: 0, boundsHeight: 600)
        XCTAssertEqual(rect.origin.x, 50, accuracy: 0.01)
        XCTAssertEqual(rect.origin.y, 600 - 100 - 18, accuracy: 0.01)
    }

    func testPinViewRectAppliesScaleAndFlip() {
        let layerRect = CGRect(x: 10, y: 20, width: 0, height: 0)
        let boundsH: CGFloat = 400
        let fs: CGFloat = 20
        let full = "ab"
        let w = IMECaretGeometry.prefixWidth(fullText: full, prefixLength: 2, fontSize: fs)
        let h = IMECaretGeometry.lineHeight(for: full, fontSize: fs)
        let scale: CGFloat = 2
        let rect = IMECaretGeometry.pinViewRect(layerRect: layerRect, fullText: full, fontSize: fs, prefixLength: 2, boundsHeight: boundsH, displayScale: scale)
        XCTAssertEqual(rect.origin.x, (layerRect.origin.x + w) * scale, accuracy: 0.01)
        XCTAssertEqual(rect.origin.y, boundsH - layerRect.origin.y * scale - h * scale, accuracy: 0.01)
        XCTAssertEqual(rect.size.width, 8 * scale, accuracy: 0.01)
        XCTAssertEqual(rect.size.height, (h + 6) * scale, accuracy: 0.01)
    }

    // MARK: - AnnotationState markedText / displayLayers

    func testDisplayLayersAppendsMarkedTextInsteadOfCursor() {
        let state = AnnotationState(styleStore: FakeStyleStore())
        state.tool = .text
        _ = state.beginDraw(at: CGPoint(x: 10, y: 10))
        guard let id = state.editingTextID, let idx = state.layers.firstIndex(id: id) else {
            XCTFail("应进入文字编辑态")
            return
        }
        // committed 写入 “ab”
        state.insertText("ab")
        XCTAssertEqual(state.layers[idx].text, "ab")
        // 无合成时 displayLayers 带光标
        XCTAssertTrue(state.displayLayers[state.displayLayers.firstIndex(id: id)!].text.hasSuffix("|"))
        // 进入合成 “拼”
        state.markedText = "拼"
        let preview = state.displayLayers[state.displayLayers.firstIndex(id: id)!].text
        XCTAssertEqual(preview, "ab拼", "合成中应为原文+marked，不带光标")
        XCTAssertFalse(preview.contains("|"))
        // 提交后清合成
        state.markedText = nil
        XCTAssertTrue(state.displayLayers[state.displayLayers.firstIndex(id: id)!].text.hasSuffix("|"))
    }

    func testMarkedTextEmptyTreatedAsNilCursor() {
        let state = AnnotationState(styleStore: FakeStyleStore())
        state.tool = .text
        _ = state.beginDraw(at: CGPoint(x: 0, y: 0))
        guard let id = state.editingTextID else { XCTFail(); return }
        state.insertText("x")
        state.markedText = ""
        // displayLayers 实现把空 marked 视为非合成，应走光标分支
        let t = state.displayLayers[state.displayLayers.firstIndex(id: id)!].text
        XCTAssertEqual(t, "x|")
        state.markedText = nil
        XCTAssertEqual(state.displayLayers[state.displayLayers.firstIndex(id: id)!].text, "x|")
    }

    func testEndTextEditingClearsMarkedText() {
        let state = AnnotationState(styleStore: FakeStyleStore())
        state.tool = .text
        _ = state.beginDraw(at: CGPoint(x: 0, y: 0))
        state.markedText = "nihao"
        state.endTextEditing()
        XCTAssertNil(state.markedText)
        XCTAssertNil(state.editingTextID)
    }

    // MARK: - Toolbar 纯函数：单/双行与块宽恒取最大

    func testToolbarLayoutPureFunctionsCoherence() {
        ToolbarRegistry.registerBuiltins(into: .shared)
        CaptureActionRegistry.registerBuiltins(into: .shared, styleStore: FakeStyleStore())
        let state = AnnotationState(styleStore: FakeStyleStore())
        state.tool = .rect
        let ctx = ToolbarContext(annotation: state, scope: .capture, perform: { _ in })
        let size = ToolbarLayout.blockSize(ctx)
        let slots = ToolbarLayout.slots(origin: .zero, context: ctx)
        let rows = ToolbarLayout.rowFrames(of: slots)
        XCTAssertEqual(rows.count, 2)
        let maxW = rows.map(\.width).max() ?? 0
        XCTAssertEqual(size.width, maxW, accuracy: 0.5)
        XCTAssertEqual(size.height, ToolbarLayout.rowHeight * 2 + ToolbarLayout.interRowGap, accuracy: 0.5)
        if let union = ToolbarLayout.rowFrame(of: slots) {
            XCTAssertEqual(union.height, size.height, accuracy: 0.5)
        }
    }
}
