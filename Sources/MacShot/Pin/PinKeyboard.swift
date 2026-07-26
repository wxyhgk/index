import AppKit

/// 钉图窗口的键盘处理。快捷键刻意和截图覆盖层保持一致 ——
/// 同一条工具条，同一套按键，钉完图不需要重新学。
extension PinImageView {

    override func keyDown(with event: NSEvent) {
        if annotation.isEditingText {
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
            needsDisplay = true
            onAnnotationsChanged?()
            return
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
            annotation.endTextEditing()
            annotation.tool = tool
            needsDisplay = true
            onToolbarHeightChanged?()
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
                onToolbarHeightChanged?()
            } else if annotation.tool != nil {
                annotation.tool = nil
                needsDisplay = true
                onToolbarHeightChanged?()
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
