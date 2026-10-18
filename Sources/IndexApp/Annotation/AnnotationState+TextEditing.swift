import Foundation
import AppKit

// MARK: - 文字输入
//
// 两条输入路径：覆盖层/钉图逐键输入（`insertText` / `deleteBackward`，
// 带 IME 合成文本预览），图库编辑器绑定整段字符串（`setText`）。
// 入栈时机统一在 `endTextEditing`：新建层写出了内容算 add，
// 空着丢弃算「add 的取消」不入栈；已有层内容变了算 style。

extension AnnotationState {

    func insertText(_ text: String) {
        guard let editingTextID, let index = layers.firstIndex(id: editingTextID) else { return }
        let current = layers[index].text
        let cursor = min(editingTextCursor, current.count)
        let prefix = current.prefix(cursor)
        let suffix = current.suffix(from: current.index(current.startIndex, offsetBy: cursor))
        layers[index].text = String(prefix) + text + String(suffix)
        editingTextCursor = cursor + text.count
    }

    func deleteBackward() {
        guard let editingTextID,
              let index = layers.firstIndex(id: editingTextID),
              editingTextCursor > 0 else { return }
        let current = layers[index].text
        let cursor = editingTextCursor
        let prefix = current.prefix(cursor - 1)
        let suffix = current.suffix(from: current.index(current.startIndex, offsetBy: cursor))
        layers[index].text = String(prefix) + String(suffix)
        editingTextCursor = cursor - 1
    }

    /// 左右方向键：按字符移动光标。
    func moveCursor(_ forward: Bool) {
        guard let editingTextID, let index = layers.firstIndex(id: editingTextID) else { return }
        let len = layers[index].text.count
        editingTextCursor = max(0, min(len, editingTextCursor + (forward ? 1 : -1)))
    }

    /// 上下方向键：按行移动光标（保持列位置）。
    func moveCursorLine(_ down: Bool) {
        guard let editingTextID, let index = layers.firstIndex(id: editingTextID) else { return }
        let text = layers[index].text
        let lines = text.components(separatedBy: "\n")
        guard lines.count > 1 else { return }

        // 当前行和列
        var currentLine = 0
        var colInLine = 0
        var offset = 0
        for (i, line) in lines.enumerated() {
            if offset + line.count >= editingTextCursor {
                currentLine = i
                colInLine = editingTextCursor - offset
                break
            }
            offset += line.count + 1
            if i == lines.count - 1 {
                currentLine = i
                colInLine = editingTextCursor - offset
            }
        }

        // 目标行
        let targetLine = max(0, min(lines.count - 1, currentLine + (down ? 1 : -1)))
        let targetCol = min(colInLine, lines[targetLine].count)

        // 算目标位置的全局下标
        var globalOffset = 0
        for i in 0..<targetLine {
            globalOffset += lines[i].count + 1
        }
        editingTextCursor = globalOffset + targetCol
    }

    /// 点击定位光标：根据点击的画布坐标，算出最近的字符下标。
    func setCursorAtCanvasPoint(_ point: CGPoint) {
        guard let editingTextID, let index = layers.firstIndex(id: editingTextID) else { return }
        let layer = layers[index]
        let text = layer.text
        guard !text.isEmpty else {
            editingTextCursor = 0
            return
        }

        // 用与 TextTool.draw 相同的字体和行距算每行宽度
        let isBold = layer.bold == 1
        let isItalic = layer.italic == 1
        let weight: NSFont.Weight = isBold ? .bold : .regular
        var font = NSFont.systemFont(ofSize: layer.fontSize, weight: weight)
        if isItalic {
            font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        }
        let lineSpacing = layer.fontSize * 1.3
        let rect = layer.rect.cg
        let lines = text.components(separatedBy: "\n")

        // 算点击在哪一行
        let relY = point.y - rect.minY
        let lineIndex = max(0, min(lines.count - 1, Int(relY / lineSpacing)))
        let lineText = lines[lineIndex]

        // 算该行每字符的 x 偏移，找最近的
        let lineNS = lineText as NSString
        var bestDistance = CGFloat.greatestFiniteMagnitude
        var bestOffset = lineNS.length
        for i in 0...lineNS.length {
            let prefix = lineNS.substring(to: i) as NSString
            let width = prefix.size(withAttributes: [.font: font]).width
            let charX = rect.minX + width
            let dist = abs(point.x - charX)
            if dist < bestDistance {
                bestDistance = dist
                bestOffset = i
            }
        }

        // 该行在全文中的起始下标
        var globalOffset = 0
        for i in 0..<lineIndex {
            globalOffset += lines[i].count + 1 // +1 for \n
        }
        editingTextCursor = globalOffset + bestOffset
    }

    /// 整段替换某一层的文字。图库编辑器的文本框走这里 ——
    /// 覆盖层/钉图是逐键输入（`insertText`），编辑器是绑定一个完整字符串。
    ///
    /// 针对同一层的连续替换合并成一条 style 记录：撤销一次回到编辑前，
    /// 而不是逐键回退出几十条历史。
    func setText(id: UUID, _ text: String) {
        guard let index = layers.firstIndex(id: id), layers[index].text != text else { return }
        let before = layers[index]
        layers[index].text = text
        history.recordStyle(id: id, before: before, after: layers[index])
    }

    /// 结束输入。空文字图层直接丢弃，避免留下看不见的空壳。
    /// 入栈时机在这里而不是落点时：新建层写出了内容算 add，
    /// 空着丢弃算「add 的取消」不入栈；已有层内容变了算 style。
    func endTextEditing() {
        // 清掉合成态，避免下一次编辑带着上次的拼音残影。
        markedText = nil
        guard let id = editingTextID else { return }
        editingTextID = nil
        editingTextCursor = 0
        let original = editingTextOriginal
        editingTextOriginal = nil

        guard let index = layers.firstIndex(id: id) else { return }
        let layer = layers[index]

        if layer.text.isEmpty {
            layers.remove(id: id)
            if let original {
                history.record(.remove(original, index: index, preview: nil))
            }
            return
        }
        if let original {
            if original != layer {
                history.record(.style(id: id, before: original, after: layer))
            }
        } else {
            history.record(.add(layer, preview: nil))
        }
    }
}