import AppKit

/// 覆盖层的键盘处理。单独成文件是因为它有自己的一套优先级规则，
/// 和鼠标事件的路由逻辑混在一起会互相干扰阅读。
extension OverlayView {

    override func keyDown(with event: NSEvent) {
        // 正在输入文字时，除了 ESC / Return 之外的按键都送进文字图层。
        if annotation.isEditingText {
            handleTextInput(event)
            return
        }

        let cmd = event.modifierFlags.contains(.command)

        if cmd, event.keyCode == KeyCode.z {
            redrawIfNeeded(annotation.undo())
            return
        }

        if let tool = AnnotationTool.shortcut(forKeyCode: event.keyCode), !cmd {
            selectTool(tool)
            return
        }

        switch event.keyCode {
        case KeyCode.escape:
            // 逐级退出：先取消图层选中，再退出标注工具，最后才是整个流程。
            if annotation.select(nil) {
                redraw()
            } else if annotation.tool != nil {
                annotation.tool = nil
                redraw()
            } else {
                cancel()
            }
        case KeyCode.delete:
            // 文字输入中的退格在上面的 isEditingText 分支处理过了，这里只删选中图层。
            redrawIfNeeded(annotation.deleteSelected())
        case KeyCode.returnKey, KeyCode.keypadEnter:
            // 「确定」键。是否覆盖剪贴板由设置决定，见 AppSettings.EnterBehavior。
            // 刻意不绑到钉图：回车最容易在「文字输入刚结束又顺手按了一下」时误触发，
            // 而误触发复制最多覆盖剪贴板，误触发钉图却会凭空多出一个窗口。
            emit(AppSettings.shared.enterBehavior == .copyAndFinish ? ActionID.copy : ActionID.finish)
        case KeyCode.c where cmd:
            emit(ActionID.copy)
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
        switch event.keyCode {
        case KeyCode.escape, KeyCode.returnKey, KeyCode.keypadEnter:
            annotation.endTextEditing()
        case KeyCode.delete:
            annotation.deleteBackward()
        default:
            guard let text = event.characters, !text.isEmpty,
                  !event.modifierFlags.contains(.command) else { return }
            annotation.insertText(text)
        }
        redraw()
    }

    /// 取色器：把光标处的色值放进剪贴板。选区还没确认时也能用。
    private func copyPickedColor() {
        guard let sample = cursorSample else { return }
        Clipboard.copy(text: sample.color.hexString)
    }

    private func selectTool(_ tool: AnnotationTool?) {
        guard model.phase == .confirmed else { return }
        annotation.endTextEditing()
        annotation.tool = tool
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
        redrawIfNeeded(model.nudge(dx: dx, dy: dy, resizing: modifiers.contains(.option)))
    }
}
