import Foundation

// MARK: - 文字输入
//
// 两条输入路径：覆盖层/钉图逐键输入（`insertText` / `deleteBackward`，
// 带 IME 合成文本预览），图库编辑器绑定整段字符串（`setText`）。
// 入栈时机统一在 `endTextEditing`：新建层写出了内容算 add，
// 空着丢弃算「add 的取消」不入栈；已有层内容变了算 style。

extension AnnotationState {

    func insertText(_ text: String) {
        guard let editingTextID, let index = layers.firstIndex(id: editingTextID) else { return }
        layers[index].text += text
    }

    func deleteBackward() {
        guard let editingTextID,
              let index = layers.firstIndex(id: editingTextID),
              !layers[index].text.isEmpty else { return }
        layers[index].text.removeLast()
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