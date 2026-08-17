import AppKit

/// 覆盖层交互里的键盘与悬停状态。`hoveredControlID` 决定工具条高亮，
/// `optionHeld` 决定窗口悬停是蓝框还是紫框（整窗捕获），都由宿主持有，
/// 键盘与鼠标事件各自读写同一份状态。
final class OverlayInteractionState {
    var hoveredControlID: String?
    var pressedControlID: String?
    var focusedControlID: String?
    var widthScroll = ToolbarScrollAccumulator()
    var optionHeld = false
    var hoveredSelectionAITask: SelectionAITaskKind?
    var pressedSelectionAITask: SelectionAITaskKind?
    var hoveredSelectionAIResultAction: OverlaySelectionAIResultAction?
    var pressedSelectionAIResultAction: OverlaySelectionAIResultAction?
    var selectionAIResultPanelConsumedMouseDown = false
    var copiedSelectionAIFormat: SelectionAIExportFormat?
}

/// 覆盖层的键盘处理。单独成文件是因为它有自己的一套优先级规则，
/// 和鼠标事件的路由逻辑混在一起会互相干扰阅读。
extension OverlayView {

    override func keyDown(with event: NSEvent) {
        // 编辑模式只占一级：第一次一次性收起画笔/指针/文字与图层选择，保留截图；
        // 第二次取消整次捕获。没有进入编辑模式时仍然一次 Esc 退出。
        if event.keyCode == KeyCode.escape {
            cancelFromEscape()
            return
        }

        // plain 模式（录屏选区）没有标注和动作，只认：⏎ 确认、方向键微调。
        if mode == .plain {
            switch event.keyCode {
            case KeyCode.returnKey, KeyCode.keypadEnter:
                emit(ActionID.finish)
            case let code where KeyCode.arrows.contains(code):
                nudge(keyCode: event.keyCode, modifiers: event.modifierFlags)
            default:
                super.keyDown(with: event)
            }
            return
        }

        // 正在输入文字时，除了 ESC / Return 之外的按键都送进文字图层。
        if annotation.isEditingText {
            handleTextInput(event)
            return
        }

        let toolbarModifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if model.phase == .confirmed,
           event.keyCode == KeyCode.tab,
           toolbarModifiers.subtracting(.shift).isEmpty {
            moveToolbarFocus(by: toolbarModifiers.contains(.shift) ? -1 : 1)
            return
        }
        if focusedControlID != nil {
            switch event.keyCode {
            case KeyCode.left:
                moveToolbarFocus(by: -1)
                return
            case KeyCode.right:
                moveToolbarFocus(by: 1)
                return
            case KeyCode.space, KeyCode.returnKey, KeyCode.keypadEnter:
                activateFocusedToolbarControl()
                return
            default:
                break
            }
        }

        let cmd = event.modifierFlags.contains(.command)

        if cmd, event.keyCode == KeyCode.z {
            // ⇧⌘Z 是重做，必须先于单独的 ⌘Z 判断。
            if event.modifierFlags.contains(.shift) {
                redrawIfNeeded(annotation.redo())
            } else {
                redrawIfNeeded(annotation.undo())
            }
            return
        }

        if let tool = AnnotationTool.shortcut(forKeyCode: event.keyCode), !cmd {
            selectTool(tool)
            return
        }

        switch event.keyCode {
        case KeyCode.delete:
            // 文字输入中的退格在上面的 isEditingText 分支处理过了，这里只删选中图层。
            redrawIfNeeded(annotation.deleteSelected())
        case KeyCode.returnKey, KeyCode.keypadEnter:
            // 「确定」键。是否覆盖剪贴板由设置决定，见 AppSettings.EnterBehavior。
            // 刻意不绑到钉图：回车最容易在「文字输入刚结束又顺手按了一下」时误触发，
            // 而误触发复制最多覆盖剪贴板，误触发钉图却会凭空多出一个窗口。
            emit(capture.enterBehavior == .copyAndFinish ? ActionID.copy : ActionID.finish)
        case KeyCode.c where cmd:
            // 鼠标模式下选中了文字 → 复制文字；否则照常复制整张图。
            if !copyLiveTextSelection() { emit(ActionID.copy) }
        case KeyCode.c where event.modifierFlags.contains(.shift):
            // ⇧C：整块取字，识别选区内全部文字进剪贴板（同工具条「取字」动作）。
            emit(ActionID.copyText)
        case KeyCode.c:
            copyPickedColor()
        case KeyCode.s where cmd:
            emit(ActionID.save)
        case let code where KeyCode.arrows.contains(code):
            nudge(keyCode: event.keyCode, modifiers: event.modifierFlags)
        default:
            super.keyDown(with: event)
        }
    }

    private func handleTextInput(_ event: NSEvent) {
        // 已接管输入法时交给 NSTextInputContext 处理合成，避免直插破坏拼音候选。
        if annotation.markedText != nil {
            interpretKeyEvents([event])
            return
        }
        switch event.keyCode {
        case KeyCode.returnKey, KeyCode.keypadEnter:
            annotation.endTextEditing()
        case KeyCode.delete:
            annotation.deleteBackward()
        default:
            // 有输入法上下文时先让其解释按键（会回调 setMarkedText/insertText）
            if let inputContext = inputContext, inputContext.handleEvent(event) {
                return
            }
            guard let text = event.characters, !text.isEmpty,
                  !event.modifierFlags.contains(.command) else { return }
            annotation.insertText(text)
        }
        redraw()
    }

    /// 单独留成可测试入口：编辑状态一级，整个截图流程一级。
    func cancelFromEscape() {
        if exitEditingFromEscape() { return }
        cancel()
    }

    @discardableResult
    private func exitEditingFromEscape() -> Bool {
        guard mode == .capture else { return false }
        if stepBackSelectionAI() {
            focusedControlID = nil
            pressedControlID = nil
            redraw()
            return true
        }
        let isEditing = annotation.tool != nil
            || annotation.pointerEngaged
            || annotation.isEditingText
            || annotation.selectedID != nil
        guard isEditing else { return false }

        // 不照右键的精细逐层链退出：Esc 一次收起整套编辑态，避免文字/图层/工具
        // 叠在一起时需要按三四次。已画好的图层仍然保留。
        _ = clearLiveTextSelection()
        annotation.endTextEditing()
        _ = annotation.select(nil)
        annotation.tool = nil
        annotation.pointerEngaged = false
        focusedControlID = nil
        pressedControlID = nil
        syncLiveTextOverlay()
        redraw()
        return true
    }

    /// 取色器：把光标处的色值放进剪贴板。选区还没确认时也能用。
    private func copyPickedColor() {
        guard let sample = magnifierState.cursorSample else { return }
        Clipboard.copy(text: sample.color.hexString)
    }

    private func selectTool(_ tool: AnnotationTool?) {
        guard model.phase == .confirmed else { return }
        annotation.endTextEditing()
        toolbarContext.capabilities.deactivateAll()
        annotation.tool = tool
        // V = 主动进入鼠标模式（选字层跟着挂上）；画笔快捷键 = 离开。
        annotation.pointerEngaged = tool == nil
        syncLiveTextOverlay()
        redraw()
    }

    private func moveToolbarFocus(by offset: Int) {
        let ids = slots.compactMap { slot -> String? in
            guard let control = slot.control, control.isEnabled(toolbarContext) else { return nil }
            return control.id
        }
        focusedControlID = ToolbarFocusNavigator.next(
            in: ids,
            current: focusedControlID,
            offset: offset
        )
        redraw()
    }

    private func activateFocusedToolbarControl() {
        guard let focusedControlID,
              let control = slots.compactMap(\.control).first(where: {
                  $0.id == focusedControlID && $0.isEnabled(toolbarContext)
              })
        else { return }
        control.activate(toolbarContext)
        syncLiveTextOverlay()
        redraw()
    }

    /// 方向键微调选区：默认移动 1pt，⇧ 变 10pt，⌥ 改为拖动右上角（调尺寸）。
    private func nudge(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        let step: CGFloat = modifiers.contains(.shift) ? 10 : 1
        var dx: CGFloat = 0
        var dy: CGFloat = 0
        switch keyCode {
        case KeyCode.left:  dx = -step
        case KeyCode.right: dx = step
        case KeyCode.down:  dy = -step
        case KeyCode.up:    dy = step
        default: return
        }
        if model.nudge(dx: dx, dy: dy, resizing: modifiers.contains(.option)) {
            if !modifiers.contains(.option) {
                // 整体平移：标注跟截图框走（Y 需翻转，同 mouseDragged）
                annotation.translateAll(by: CGPoint(x: dx, y: -dy))
            }
            // 选区变了，预跑的选字分析跟着重跑（幂等，没确认选区时是空操作）；
            // 鼠标模式下选字层也贴回新位置。
            prepareLiveTextAnalysis()
            syncLiveTextOverlayFrame()
            redraw()
        }
    }
}

// MARK: - 中文输入（NSTextInputClient）
//
// 文字工具的旧实现直接 `event.characters` 插入，绕过了输入法的合成阶段，
// 导致拼音+候选窗口无法出现。此处让视图成为 NSTextInputClient，合成中的
// 字符串经 `setMarkedText` 预览在 `annotation.markedText`，提交时经
// `insertText` 落库，`firstRect` 供候选窗口跟随。
extension OverlayView: NSTextInputClient {

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
        redraw()
    }

    func unmarkText() {
        if let marked = annotation.markedText, !marked.isEmpty {
            annotation.insertText(marked)
        }
        annotation.markedText = nil
        redraw()
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        [.foregroundColor, .backgroundColor, .underlineStyle]
    }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        let committed = annotation.layers.elements.first(where: { $0.id == annotation.editingTextID })?.text ?? ""
        let marked = annotation.markedText ?? ""
        let full = committed + marked
        let nsFull = full as NSString
        let len = nsFull.length
        let loc = max(0, min(range.location, len))
        let rlen = min(range.length, len - loc)
        let sub = nsFull.substring(with: NSRange(location: loc, length: rlen))
        actualRange?.pointee = NSRange(location: loc, length: rlen)
        return NSAttributedString(string: sub)
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        // 提交合成或直插：先清合成预览，再把 string 当提交文本
        annotation.markedText = nil
        let s: String
        if let str = string as? String { s = str }
        else if let attr = string as? NSAttributedString { s = attr.string }
        else { return }
        guard !s.isEmpty else { redraw(); return }
        // 回车等控制字符在上层已处理，这里只处理可见文本
        if s == "\n" || s == "\r" {
            annotation.endTextEditing()
        } else {
            annotation.insertText(s)
        }
        redraw()
    }

    func characterIndex(for point: NSPoint) -> Int {
        let committed = annotation.layers.elements.first(where: { $0.id == annotation.editingTextID })?.text ?? ""
        return (committed as NSString).length
    }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let id = annotation.editingTextID,
              let idx = annotation.layers.firstIndex(id: id) else {
            actualRange?.pointee = NSRange(location: NSNotFound, length: 0)
            return NSRect.zero
        }
        let layer = annotation.layers[idx]
        let committed = layer.text
        let marked = annotation.markedText ?? ""
        let full = committed + marked
        let viewRect = IMECaretGeometry.overlayViewRect(
            layerRect: layer.rect.cg,
            fullText: full,
            fontSize: CGFloat(layer.fontSize),
            prefixLength: range.location,
            boundsHeight: bounds.height
        )
        let windowRect = convert(viewRect, to: nil)
        let screenRect = window?.convertToScreen(windowRect) ?? windowRect
        actualRange?.pointee = NSRange(location: range.location, length: min(range.length, (full as NSString).length - range.location))
        return screenRect
    }

}
