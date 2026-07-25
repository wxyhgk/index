import AppKit

/// 钉图窗口的键盘处理。快捷键刻意和截图覆盖层保持一致 ——
/// 同一条工具条，同一套按键，钉完图不需要重新学。
extension PinImageView {

    private enum Key {
        static let escape: UInt16 = 53
        static let returnKey: UInt16 = 36
        static let keypadEnter: UInt16 = 76
        static let delete: UInt16 = 51
        static let c: UInt16 = 8
        static let s: UInt16 = 1
        static let z: UInt16 = 6
    }

    private static let toolShortcuts: [UInt16: AnnotationTool?] = [
        9:  AnnotationTool?.none, // V 指针
        15: .rect,                // R 矩形
        31: .ellipse,             // O 椭圆
        0:  .arrow,               // A 箭头
        17: .text,                // T 文字
        4:  .highlight,           // H 高亮
        35: .pixelate             // P 马赛克
    ]

    override func keyDown(with event: NSEvent) {
        if annotation.isEditingText {
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
            needsDisplay = true
            onAnnotationsChanged?()
            return
        }

        let cmd = event.modifierFlags.contains(.command)

        if cmd, event.keyCode == Key.z {
            annotation.undo()
            needsDisplay = true
            onAnnotationsChanged?()
            return
        }

        if let tool = Self.toolShortcuts[event.keyCode], !cmd {
            annotation.endTextEditing()
            annotation.tool = tool
            needsDisplay = true
            onToolbarHeightChanged?()
            return
        }

        switch event.keyCode {
        case Key.returnKey, Key.keypadEnter:
            // 和截图阶段用同一个设置。选了「完成不复制」时这里什么也不做 ——
            // 钉图已经在屏幕上了，没有别的「完成」可言。
            if AppSettings.shared.enterBehavior == .copyAndFinish {
                onAction?(.copy)
            }
        case Key.escape:
            // 先放下画笔，再关窗口 —— 不要一下子把画到一半的东西全丢了。
            if annotation.tool != nil {
                annotation.tool = nil
                needsDisplay = true
                onToolbarHeightChanged?()
            } else {
                onAction?(.close)
            }
        case Key.c where cmd:
            onAction?(.copy)
        case Key.s where cmd:
            onAction?(.save)
        default:
            super.keyDown(with: event)
        }
    }
}
