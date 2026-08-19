import AppKit

// MARK: - 覆盖层手势 target
//
// 每个 target 是覆盖层里的一个交互子系统，只依赖 `OverlayGestureHost` 门面。
// 优先级与注册在 `OverlayInteractionRouter.defaultTargets()`。
//
// 行为与重构前视图里的 if/else 链逐条对应 —— 迁移时不改语义，只改归属。

/// AI 选区结果面板（复制/关闭按钮）。
@MainActor
struct OverlayAIResultPanelTarget: OverlayGestureTarget {

    func mouseDown(local: CGPoint, event: NSEvent, host: OverlayGestureHost) -> Bool {
        guard let layout = host.selectionAIResultLayout,
              layout.frame.contains(local) else { return false }
        host.interactionState.selectionAIResultPanelConsumedMouseDown = true
        host.interactionState.pressedSelectionAIResultAction = layout.actionSlots.first {
            $0.frame.contains(local)
        }?.action
        host.interactionState.hoveredSelectionAIResultAction =
            host.interactionState.pressedSelectionAIResultAction
        host.interactionState.focusedControlID = nil
        host.redraw()
        return true
    }

    func mouseDragged(local: CGPoint, event: NSEvent, host: OverlayGestureHost) {
        if let pressed = host.interactionState.pressedSelectionAIResultAction {
            host.interactionState.hoveredSelectionAIResultAction =
                host.selectionAIResultLayout?.actionSlots.contains {
                    $0.action == pressed && $0.frame.contains(local)
                } == true ? pressed : nil
        }
        host.redraw()
    }

    func mouseUp(local: CGPoint, event: NSEvent, host: OverlayGestureHost) {
        guard host.interactionState.selectionAIResultPanelConsumedMouseDown else { return }
        let pressed = host.interactionState.pressedSelectionAIResultAction
        let activated = pressed.flatMap { pressed in
            host.selectionAIResultLayout?.actionSlots.first {
                $0.action == pressed && $0.frame.contains(local)
            }?.action
        }
        host.interactionState.selectionAIResultPanelConsumedMouseDown = false
        host.interactionState.pressedSelectionAIResultAction = nil
        host.interactionState.hoveredSelectionAIResultAction = activated
        if let activated { host.performSelectionAIResultAction(activated) }
        host.redraw()
    }

    func hover(local: CGPoint, host: OverlayGestureHost) {
        let action = host.selectionAIResultLayout?.actionSlots.first {
            $0.frame.contains(local)
        }?.action
        if action != host.interactionState.hoveredSelectionAIResultAction {
            host.interactionState.hoveredSelectionAIResultAction = action
            host.redraw()
        }
    }

    func cursor(local: CGPoint, host: OverlayGestureHost) -> OverlayCursorDecision? {
        guard let layout = host.selectionAIResultLayout,
              layout.frame.contains(local) else { return nil }
        return .set(.arrow)
    }
}

/// AI 选区任务板（选区旁的任务快捷入口）。
@MainActor
struct OverlayAITaskPaletteTarget: OverlayGestureTarget {

    func mouseDown(local: CGPoint, event: NSEvent, host: OverlayGestureHost) -> Bool {
        guard let task = host.selectionAITaskSlots.first(where: { $0.frame.contains(local) })?.kind
        else { return false }
        host.interactionState.pressedSelectionAITask = task
        host.interactionState.hoveredSelectionAITask = task
        host.interactionState.focusedControlID = nil
        host.redraw()
        return true
    }

    func mouseDragged(local: CGPoint, event: NSEvent, host: OverlayGestureHost) {
        if let pressed = host.interactionState.pressedSelectionAITask {
            let inside = host.selectionAITaskSlots.contains {
                $0.kind == pressed && $0.frame.contains(local)
            }
            host.interactionState.hoveredSelectionAITask = inside ? pressed : nil
        }
        host.redraw()
    }

    func mouseUp(local: CGPoint, event: NSEvent, host: OverlayGestureHost) {
        guard let pressed = host.interactionState.pressedSelectionAITask else { return }
        let activated = host.selectionAITaskSlots.contains {
            $0.kind == pressed && $0.frame.contains(local)
        }
        host.interactionState.pressedSelectionAITask = nil
        host.interactionState.hoveredSelectionAITask = activated ? pressed : nil
        if activated { host.performSelectionAITask(pressed) }
        host.redraw()
    }

    func hover(local: CGPoint, host: OverlayGestureHost) {
        let task = host.selectionAITaskSlots.first { $0.frame.contains(local) }?.kind
        if task != host.interactionState.hoveredSelectionAITask {
            host.interactionState.hoveredSelectionAITask = task
            host.redraw()
        }
    }

    func cursor(local: CGPoint, host: OverlayGestureHost) -> OverlayCursorDecision? {
        guard host.selectionAITaskSlots.contains(where: { $0.frame.contains(local) }) else { return nil }
        return .set(.arrow)
    }
}

/// 工具条控件（绘制/命中同源，见 `ToolbarSlot`）。
@MainActor
struct OverlayToolbarTarget: OverlayGestureTarget {

    func mouseDown(local: CGPoint, event: NSEvent, host: OverlayGestureHost) -> Bool {
        guard host.model.phase == .confirmed else { return false }
        // hitFrame 比视觉区外扩，见 ToolbarSlot.hitFrame。
        if let control = host.slots.first(where: { $0.control != nil && $0.hitFrame.contains(local) })?.control {
            // 禁用控件也记录按下，以便 mouseUp 被工具条消费；是否执行在松开时判断。
            host.interactionState.pressedControlID = control.id
            host.interactionState.hoveredControlID = control.id
            host.interactionState.focusedControlID = control.id
            host.redraw()
            return true
        }
        // 按在工具条外：清掉悬停与键盘焦点。
        host.interactionState.hoveredControlID = nil
        host.interactionState.focusedControlID = nil
        return false
    }

    func mouseDragged(local: CGPoint, event: NSEvent, host: OverlayGestureHost) {
        guard let pressedID = host.interactionState.pressedControlID else { return }
        let stillInside = host.slots.contains {
            $0.control?.id == pressedID && $0.hitFrame.contains(local)
        }
        let nextHover = stillInside ? pressedID : nil
        if nextHover != host.interactionState.hoveredControlID {
            host.interactionState.hoveredControlID = nextHover
            host.redraw()
        }
    }

    func mouseUp(local: CGPoint, event: NSEvent, host: OverlayGestureHost) {
        guard let pressedID = host.interactionState.pressedControlID else { return }
        let control = host.slots.first {
            $0.control?.id == pressedID && $0.hitFrame.contains(local)
        }?.control
        host.interactionState.pressedControlID = nil
        host.interactionState.hoveredControlID = control?.id
        if let control, control.isEnabled(host.toolbarContext) {
            control.activate(host.toolbarContext)
            host.syncLiveTextOverlay()
        }
        host.redraw()
    }

    func hover(local: CGPoint, host: OverlayGestureHost) {
        guard host.model.phase == .confirmed else { return }
        let hit = host.slots.first { $0.control != nil && $0.hitFrame.contains(local) }?.control?.id
        if hit != host.interactionState.hoveredControlID {
            host.interactionState.hoveredControlID = hit
            host.redraw()
        }
    }

    func cursor(local: CGPoint, host: OverlayGestureHost) -> OverlayCursorDecision? {
        guard host.model.phase == .confirmed,
              host.slots.contains(where: { $0.control != nil && $0.hitFrame.contains(local) })
        else { return nil }
        return .set(.arrow)
    }
}

/// AI 选区手势（在已确认选区内框 AI 选区）。
@MainActor
struct OverlayAIGestureTarget: OverlayGestureTarget {

    func mouseDown(local: CGPoint, event: NSEvent, host: OverlayGestureHost) -> Bool {
        // AI 选区是已确认截图内部的临时手势，优先于标注与原选区调整。
        guard host.beginSelectionAI(atViewLocal: local) else { return false }
        host.becameActive()
        host.redraw()
        return true
    }

    func mouseDragged(local: CGPoint, event: NSEvent, host: OverlayGestureHost) {
        _ = host.updateSelectionAI(atViewLocal: local)
        host.redraw()
    }

    func mouseUp(local: CGPoint, event: NSEvent, host: OverlayGestureHost) {
        _ = host.endSelectionAI(atViewLocal: local)
        host.redraw()
    }

    func hover(local: CGPoint, host: OverlayGestureHost) {}

    func cursor(local: CGPoint, host: OverlayGestureHost) -> OverlayCursorDecision? {
        guard host.model.phase == .confirmed,
              host.selectionAIHostIsActive,
              let rect = host.model.confirmedRect,
              rect.contains(host.geometry.global(fromViewLocal: local))
        else { return nil }
        return .set(.crosshair)
    }
}

/// ⌥+单击窗口 = 整窗捕获（不含遮挡）。
@MainActor
struct OverlayFullWindowTarget: OverlayGestureTarget {

    func mouseDown(local: CGPoint, event: NSEvent, host: OverlayGestureHost) -> Bool {
        guard host.allowsFullWindowCapture, host.model.phase == .idle,
              event.modifierFlags.contains(.option) else { return false }
        let global = host.geometry.global(fromViewLocal: local)
        // 这块屏可能因为别的屏正在操作而被标记 inactive（hover 会被吞掉）——
        // 用户既然点到这里了，就把它激活。
        host.model.setInactive(false)
        host.model.hover(at: global)
        guard let window = host.model.hoveredWindow else { return false }
        host.emitFullWindow(window)
        return true
    }

    func mouseDragged(local: CGPoint, event: NSEvent, host: OverlayGestureHost) {}
    func mouseUp(local: CGPoint, event: NSEvent, host: OverlayGestureHost) {}
    func hover(local: CGPoint, host: OverlayGestureHost) {}
    func cursor(local: CGPoint, host: OverlayGestureHost) -> OverlayCursorDecision? { nil }
}

/// plain 模式（录屏选区）：双击选区内部 = 确认返回。
@MainActor
struct OverlayPlainConfirmTarget: OverlayGestureTarget {

    func mouseDown(local: CGPoint, event: NSEvent, host: OverlayGestureHost) -> Bool {
        guard host.mode == .plain, host.model.phase == .confirmed,
              event.clickCount == 2,
              host.model.confirmedRect?.contains(host.geometry.global(fromViewLocal: local)) == true
        else { return false }
        host.emit(ActionID.finish)
        return true
    }

    func mouseDragged(local: CGPoint, event: NSEvent, host: OverlayGestureHost) {}
    func mouseUp(local: CGPoint, event: NSEvent, host: OverlayGestureHost) {}
    func hover(local: CGPoint, host: OverlayGestureHost) {}
    func cursor(local: CGPoint, host: OverlayGestureHost) -> OverlayCursorDecision? { nil }
}

/// 标注：工具绘制、图层选中/拖动/缩放、指针模式图层命中。
@MainActor
struct OverlayAnnotationTarget: OverlayGestureTarget {

    func mouseDown(local: CGPoint, event: NSEvent, host: OverlayGestureHost) -> Bool {
        guard host.model.phase == .confirmed else { return false }
        let global = host.geometry.global(fromViewLocal: local)
        let selection = host.model.confirmedRect

        // 手上有标注工具时，选区内的拖拽是画标注，不是调整选区。
        // 例外：命中选区边缘控制点时放行给 OverlaySelectionTarget 做 resize ——
        // 控制点的 9pt 命中范围大部分在选区外，不拦的话 restoreLastTool 恢复
        // 工具后选框就再也拉不动了。
        if host.annotation.tool != nil {
            if let handle = host.model.handle(at: global), handle != .inside {
                return false
            }
            if let selection, selection.contains(global) {
                host.annotation.beginDraw(at: host.geometry.annotationPoint(fromViewLocal: local))
                host.redraw()
                return true
            }
            return true
        }

        // 鼠标模式（tool == nil 且 pointerEngaged）下优先命中选中图层的缩放控制点；
        // 再是图层本体（选中并准备拖动）；点空处 → 取消选中 + 清掉选字层的文字选择，
        // 落回选区调整逻辑（不消费）。中性态（未点「鼠标」）不做图层命中。
        // 只在选区内测试：图层出了选区的部分是看不见的。
        // 文字上的点击到不了这里 —— 鼠标模式下由选字层的命中测试包装接走（拖 = 选字）。
        guard host.annotation.tool == nil, host.annotation.pointerEngaged,
              let selection, selection.contains(global) else { return false }
        let canvas = host.geometry.annotationPoint(fromViewLocal: local)
        if let handle = host.annotation.resizeHandle(at: canvas) {
            host.annotation.endTextEditing()
            host.annotation.beginResize(handle: handle, at: canvas)
            host.becameActive()
            host.redraw()
            return true
        }
        if let id = host.annotation.layer(at: canvas) {
            host.annotation.endTextEditing()
            host.annotation.beginMove(id: id, at: canvas)
            host.becameActive()
            host.redraw()
            return true
        }
        host.redrawIfNeeded(host.annotation.select(nil))
        if let overlay = host.liveTextOverlay, overlay.hasActiveTextSelection {
            overlay.resetSelection()
        }
        return false
    }

    func mouseDragged(local: CGPoint, event: NSEvent, host: OverlayGestureHost) {
        let canvas = host.geometry.annotationPoint(fromViewLocal: local)
        if host.annotation.isDrawing {
            host.redrawIfNeeded(host.annotation.updateDraw(to: canvas))
        } else if host.annotation.isMoving {
            host.redrawIfNeeded(host.annotation.updateMove(to: canvas))
        } else if host.annotation.isResizing {
            host.redrawIfNeeded(host.annotation.updateResize(to: canvas))
        }
    }

    func mouseUp(local: CGPoint, event: NSEvent, host: OverlayGestureHost) {
        // 马赛克要从冻结画面取原始像素：闭包在 end* 内部按需调用。
        let pixels: (CGRect) -> CGImage? = { host.frozenPixels($0) }
        if host.annotation.isDrawing {
            host.annotation.endDraw(pixelSource: pixels)
            host.redraw()
        } else if host.annotation.isMoving {
            host.annotation.endMove(pixelSource: pixels)
            host.redraw()
        } else if host.annotation.isResizing {
            host.annotation.endResize(pixelSource: pixels)
            host.redraw()
        }
    }

    func hover(local: CGPoint, host: OverlayGestureHost) {}

    func cursor(local: CGPoint, host: OverlayGestureHost) -> OverlayCursorDecision? {
        guard host.model.phase == .confirmed else { return nil }
        // 鼠标模式下文字上的光标（I-beam）由系统选字层自己管，这里不抢。
        if host.annotation.pointerEngaged,
           host.hasLiveTextInteractiveItem(atViewLocal: local) {
            return .leaveAlone
        }
        if host.annotation.tool != nil {
            // 命中选区控制点时不表态，让 OverlaySelectionTarget 给出 resize 光标。
            if let handle = host.model.handle(at: host.geometry.global(fromViewLocal: local)),
               handle != .inside {
                return nil
            }
            return .set(.crosshair)
        }
        // 选中图层的缩放控制点优先于选区自身的控制点 —— 命中顺序和 mouseDown 一致。
        if host.annotation.pointerEngaged,
           let rect = host.model.confirmedRect,
           rect.contains(host.geometry.global(fromViewLocal: local)),
           let handle = host.annotation.resizeHandle(
               at: host.geometry.annotationPoint(fromViewLocal: local)
           ) {
            return .set(handle.cursor)
        }
        return nil
    }
}

/// 选区：画新选区、调整已有选区、确认收尾。
/// 数组里恒在最后，`mouseDown` 恒为 true —— 兜底。
@MainActor
struct OverlaySelectionTarget: OverlayGestureTarget {

    func mouseDown(local: CGPoint, event: NSEvent, host: OverlayGestureHost) -> Bool {
        host.annotation.endTextEditing()
        let global = host.geometry.global(fromViewLocal: local)
        // 点在已有选区的控制点或内部 → 调整，而不是重画
        if let handle = host.model.handle(at: global) {
            host.model.beginAdjust(handle: handle, at: global)
            if handle.isMove { NSCursor.closedHand.set() }
        } else {
            host.model.beginDrag(at: global)
        }
        host.becameActive()
        host.redraw()
        return true
    }

    func mouseDragged(local: CGPoint, event: NSEvent, host: OverlayGestureHost) {
        let global = host.geometry.global(fromViewLocal: local)
        switch host.model.phase {
        case .adjusting:
            let oldRect = host.model.confirmedRect
            let wasMove = host.model.adjustingHandle?.isMove == true
            host.model.updateAdjust(to: global)
            if wasMove, let oldRect, let newRect = host.model.confirmedRect {
                let dx = newRect.origin.x - oldRect.origin.x
                let dy = newRect.origin.y - oldRect.origin.y
                // AppKit Y 向上，画布 Y 向下
                host.annotation.translateAll(by: CGPoint(x: dx, y: -dy))
            }
        default:
            host.model.updateDrag(to: global)
        }
        host.redraw()
    }

    func mouseUp(local: CGPoint, event: NSEvent, host: OverlayGestureHost) {
        switch host.model.phase {
        case .adjusting:
            host.model.endAdjust()
            host.prepareLiveTextAnalysis()
            // 鼠标模式下调整了选区：选字层贴回新位置、套用重跑的分析。
            host.syncLiveTextOverlayFrame()
            host.interactionState.hoveredControlID = nil
            NSCursor.arrow.set()
        default:
            if host.model.endDrag() {
                if host.finishOnConfirm {
                    // 简单模式：确认即返回，不进 confirmed 阶段的工具条/标注流程。
                    host.emit(ActionID.finish)
                    return
                }
                host.enterConfirmedState()
            }
        }
        host.redraw()
    }

    func hover(local: CGPoint, host: OverlayGestureHost) {}

    func cursor(local: CGPoint, host: OverlayGestureHost) -> OverlayCursorDecision? {
        let handle = host.model.handle(at: host.geometry.global(fromViewLocal: local))
        return .set(handle?.cursor ?? .crosshair)
    }
}