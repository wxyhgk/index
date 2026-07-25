import AppKit

/// 覆盖层的键盘处理。单独成文件是因为它有自己的一套优先级规则，
/// 和鼠标事件的路由逻辑混在一起会互相干扰阅读。
extension OverlayView {

    private enum Key {
        static let escape: UInt16 = 53
        static let returnKey: UInt16 = 36
        static let keypadEnter: UInt16 = 76
        static let delete: UInt16 = 51
        static let c: UInt16 = 8
        static let s: UInt16 = 1
        static let z: UInt16 = 6
        static let left: UInt16 = 123
        static let right: UInt16 = 124
        static let down: UInt16 = 125
        static let up: UInt16 = 126
    }

    /// 工具快捷键，和工具条上的顺序一致。
    /// 值是双层可选：字典查得到表示「这个键绑了工具」，内层 nil 表示指针模式。
    private static let toolShortcuts: [UInt16: AnnotationTool?] = [
        9:  AnnotationTool?.none, // V 指针
        15: .rect,               // R 矩形
        31: .ellipse,            // O 椭圆
        0:  .arrow,              // A 箭头
        17: .text,               // T 文字
        4:  .highlight,          // H 高亮
        35: .pixelate            // P 马赛克
    ]

    override func keyDown(with event: NSEvent) {
        // 正在输入文字时，除了 ESC / Return 之外的按键都送进文字图层。
        if annotation.isEditingText {
            handleTextInput(event)
            return
        }

        let cmd = event.modifierFlags.contains(.command)

        if cmd, event.keyCode == Key.z {
            redrawIfNeeded(annotation.undo())
            return
        }

        if let tool = Self.toolShortcuts[event.keyCode], !cmd {
            selectTool(tool)
            return
        }

        switch event.keyCode {
        case Key.escape:
            // 先退出标注工具，再退出整个流程 —— 不要一下子把选区也丢了。
            if annotation.tool != nil {
                annotation.tool = nil
                redraw()
            } else {
                cancel()
            }
        case Key.returnKey, Key.keypadEnter:
            emit(.pin)
        case Key.c where cmd:
            emit(.copy)
        case Key.s where cmd:
            emit(.save)
        case Key.left, Key.right, Key.down, Key.up:
            nudge(keyCode: event.keyCode, modifiers: event.modifierFlags)
        default:
            super.keyDown(with: event)
        }
    }

    private func handleTextInput(_ event: NSEvent) {
        switch event.keyCode {
        case Key.escape, Key.returnKey, Key.keypadEnter:
            annotation.endTextEditing()
        case Key.delete:
            annotation.deleteBackward()
        default:
            guard let text = event.characters, !text.isEmpty,
                  !event.modifierFlags.contains(.command) else { return }
            annotation.insertText(text)
        }
        redraw()
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
        case Key.left:  dx = -step
        case Key.right: dx = step
        case Key.down:  dy = -step
        case Key.up:    dy = step
        default: return
        }
        redrawIfNeeded(model.nudge(dx: dx, dy: dy, resizing: modifiers.contains(.option)))
    }
}
