import AppKit

/// 钉图窗口的键盘处理。快捷键刻意和截图覆盖层保持一致 ——
/// 同一条工具条，同一套按键，钉完图不需要重新学。
extension PinImageView {

    override func keyDown(with event: NSEvent) {
        // 切工具、退选中、撤销都会改变工具条上有哪些控件可见 ——
        // 走哪条分支都让工具条窗口重算一次（它是独立窗口，收不到这些按键）。
        defer { onToolbarInvalidated?() }

        if annotation.isEditingText {
            if annotation.markedText != nil {
                interpretKeyEvents([event])
                needsDisplay = true
                onAnnotationsChanged?()
                return
            }
            switch event.keyCode {
            case KeyCode.escape, KeyCode.returnKey, KeyCode.keypadEnter:
                annotation.endTextEditing()
            case KeyCode.delete:
                annotation.deleteBackward()
            default:
                if let inputContext = inputContext, inputContext.handleEvent(event) {
                    needsDisplay = true
                    onAnnotationsChanged?()
                    return
                }
                guard let text = event.characters, !text.isEmpty,
                      !event.modifierFlags.contains(.command) else { return }
                annotation.insertText(text)
            }
            needsDisplay = true
            onAnnotationsChanged?()
            return
        }

        // 选字模式：⎋ 退出（Esc 链最前面加的一级）；⌘C 优先复制选中的文字；
        // 切工具快捷键放行，下面的分支会先退出选字再拿起工具；
        // ⌘Z 也放行 —— commitAnnotationChange 会把分析对齐到撤销后的画面。
        if isLiveTextActive {
            switch event.keyCode {
            case KeyCode.escape:
                exitLiveText()
                return
            case KeyCode.c where event.modifierFlags.contains(.command):
                if copyLiveTextSelection() { return }
            default:
                break
            }
        }

        let cmd = event.modifierFlags.contains(.command)

        if cmd, event.keyCode == KeyCode.z {
            // ⇧⌘Z 是重做，必须先于单独的 ⌘Z 判断。
            // 撤销/重做可能增删马赛克层，走 commitAnnotationChange 重算底图并落库。
            let changed = event.modifierFlags.contains(.shift)
                ? annotation.redo()
                : annotation.undo()
            if changed { commitAnnotationChange() }
            return
        }

        if let tool = AnnotationTool.shortcut(forKeyCode: event.keyCode), !cmd {
            exitLiveText()
            annotation.endTextEditing()
            annotation.tool = tool
            needsDisplay = true
            return
        }

        switch event.keyCode {
        case KeyCode.returnKey, KeyCode.keypadEnter:
            // 和截图阶段用同一个设置。选了「完成不复制」时这里什么也不做 ——
            // 钉图已经在屏幕上了，没有别的「完成」可言。
            if AppSettings.shared.enterBehavior == .copyAndFinish {
                onAction?(ActionID.copy)
            }
        case KeyCode.escape:
            // 逐级退出：先取消图层选中，再放下画笔，最后才关窗口。
            if annotation.select(nil) {
                needsDisplay = true
            } else if annotation.tool != nil {
                annotation.tool = nil
                needsDisplay = true
            } else {
                onAction?(ActionID.close)
            }
        case KeyCode.delete:
            // 文字输入中的退格在上面的 isEditingText 分支处理过了，这里只删选中图层。
            if annotation.deleteSelected() {
                commitAnnotationChange()
            }
        case KeyCode.c where cmd:
            onAction?(ActionID.copy)
        case KeyCode.t where cmd:
            // 鼠标穿透。开了之后窗口收不到任何事件，解除走菜单栏「解除钉图穿透」。
            onTogglePassthrough?()
        case KeyCode.s where cmd:
            onAction?(ActionID.save)
        default:
            super.keyDown(with: event)
        }
    }
}

// MARK: - 中文输入（与 OverlayView 同款，复用 annotation.markedText）
extension PinImageView: NSTextInputClient {

    func hasMarkedText() -> Bool { annotation.markedText != nil }

    func markedRange() -> NSRange {
        guard let marked = annotation.markedText else { return NSRange(location: NSNotFound, length: 0) }
        let committed = annotation.layers.elements.first(where: { $0.id == annotation.editingTextID })?.text ?? ""
        return NSRange(location: (committed as NSString).length, length: (marked as NSString).length)
    }

    func selectedRange() -> NSRange {
        let committed = annotation.layers.elements.first(where: { $0.id == annotation.editingTextID })?.text ?? ""
        let markedLen = (annotation.markedText as NSString?)?.length ?? 0
        return NSRange(location: (committed as NSString).length + markedLen, length: 0)
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let s: String
        if let str = string as? String { s = str }
        else if let attr = string as? NSAttributedString { s = attr.string }
        else { s = "" }
        annotation.markedText = s.isEmpty ? nil : s
        needsDisplay = true
        onAnnotationsChanged?()
    }

    func unmarkText() {
        if let marked = annotation.markedText, !marked.isEmpty { annotation.insertText(marked) }
        annotation.markedText = nil
        needsDisplay = true
        onAnnotationsChanged?()
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [.foregroundColor, .backgroundColor, .underlineStyle] }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        let committed = annotation.layers.elements.first(where: { $0.id == annotation.editingTextID })?.text ?? ""
        let marked = annotation.markedText ?? ""
        let full = committed + marked
        let nsFull = full as NSString
        let loc = max(0, min(range.location, nsFull.length))
        let rlen = min(range.length, nsFull.length - loc)
        actualRange?.pointee = NSRange(location: loc, length: rlen)
        return NSAttributedString(string: nsFull.substring(with: NSRange(location: loc, length: rlen)))
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        annotation.markedText = nil
        let s: String
        if let str = string as? String { s = str }
        else if let attr = string as? NSAttributedString { s = attr.string }
        else { return }
        guard !s.isEmpty else { needsDisplay = true; return }
        if s == "\n" || s == "\r" { annotation.endTextEditing() }
        else { annotation.insertText(s) }
        needsDisplay = true
        onAnnotationsChanged?()
    }

    func characterIndex(for point: NSPoint) -> Int {
        (annotation.layers.elements.first(where: { $0.id == annotation.editingTextID })?.text as NSString?)?.length ?? 0
    }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let id = annotation.editingTextID, let idx = annotation.layers.firstIndex(id: id) else {
            actualRange?.pointee = NSRange(location: NSNotFound, length: 0)
            return NSRect.zero
        }
        let layer = annotation.layers[idx]
        let font = NSFont.systemFont(ofSize: CGFloat(layer.fontSize), weight: .semibold)
        let full = layer.text + (annotation.markedText ?? "")
        let prefixLen = min(range.location, (full as NSString).length)
        let prefix = (full as NSString).substring(to: prefixLen)
        let width = (prefix as NSString).size(withAttributes: [.font: font]).width
        // Pin 画布坐标即图片像素，已在 draw 时按倍率缩放，这里近似用 layer.rect
        let rect = NSRect(x: layer.rect.x + width, y: layer.rect.y, width: 8, height: CGFloat(layer.fontSize) + 6)
        let viewRect = convert(rect, to: nil)
        let screenRect = window?.convertToScreen(viewRect) ?? viewRect
        actualRange?.pointee = NSRange(location: range.location, length: min(range.length, (full as NSString).length - range.location))
        return screenRect
    }

}
