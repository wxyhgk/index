import AppKit

// ============================================================
// MARK: - 内置工具条控件：样式参数调节
//
// ColorControl / ColorPickerControl / WidthSliderControl /
// FontSizeCapsuleControl / ToolParamControl / BoldControl /
// ItalicControl / EffectToggleControl。
// ============================================================

// MARK: - 颜色与粗细

struct ColorControl: ToolbarControl {
    let index: Int

    var id: String { "color.\(index)" }
    var scopes: Set<ActionScope> { [.capture, .pinned] }
    var group: ToolbarGroup { .style }
    var order: Int { index }

    /// 只在当前工具声明了颜色轴时显示（放大镜/裁剪/聚光灯/马赛克/橡皮擦不显示）。
    func isVisible(_ context: ToolbarContext) -> Bool {
        context.annotation.styleAxes.contains(.color)
    }
    func isSelected(_ context: ToolbarContext) -> Bool {
        context.annotation.styleIndex(for: .color) == index
    }
    func accessibilityLabel(_ context: ToolbarContext) -> String { "颜色 \(index + 1)" }
    func width(_ context: ToolbarContext) -> CGFloat { ToolbarStyle.swatchWidth }

    func draw(in frame: CGRect, context: ToolbarContext, state: ToolbarRenderState) {
        let color = AnnotationState.palette[index]
        let size: CGFloat = 14
        let corner: CGFloat = 4
        let rect = CGRect(x: frame.midX - size / 2, y: frame.midY - size / 2, width: size, height: size)
        let path = NSBezierPath(roundedRect: rect, xRadius: corner, yRadius: corner)

        NSColor(srgbRed: color.r, green: color.g, blue: color.b, alpha: 1).setFill()
        path.fill()

        if state.isSelected {
            // 选中态：彩虹边框（PixPin 风格）—— 环形路径 + 渐变填充
            let outer = NSBezierPath(roundedRect: rect.insetBy(dx: -2.5, dy: -2.5), xRadius: corner + 2, yRadius: corner + 2)
            let inner = NSBezierPath(roundedRect: rect, xRadius: corner, yRadius: corner)
            let ring = NSBezierPath()
            ring.append(outer)
            ring.append(inner)
            ring.windingRule = .evenOdd
            let colors: [NSColor] = [
                NSColor(srgbRed: 1, green: 0.3, blue: 0.3, alpha: 1),
                NSColor(srgbRed: 1, green: 0.8, blue: 0.2, alpha: 1),
                NSColor(srgbRed: 0.3, green: 1, blue: 0.4, alpha: 1),
                NSColor(srgbRed: 0.3, green: 0.6, blue: 1, alpha: 1),
                NSColor(srgbRed: 0.8, green: 0.4, blue: 1, alpha: 1),
            ]
            if let gradient = NSGradient(colors: colors) {
                gradient.draw(in: ring, relativeCenterPosition: .zero)
            }
        }
    }

    func activate(_ context: ToolbarContext) {
        context.annotation.selectPaletteColor(index)
    }
}

/// 取色器（吸管）：点击进入取色模式，鼠标点画布采样像素设为当前颜色。
struct ColorPickerControl: ToolbarControl {
    static let controlID = "colorPicker"

    var id: String { Self.controlID }
    var scopes: Set<ActionScope> { [.capture, .pinned] }
    var group: ToolbarGroup { .style }
    /// 排在调色板色块之后（order 900）。
    var order: Int { 900 }

    /// 只在当前工具声明了颜色轴时显示。
    func isVisible(_ context: ToolbarContext) -> Bool {
        context.annotation.styleAxes.contains(.color)
    }
    func isSelected(_ context: ToolbarContext) -> Bool {
        context.annotation.isPickingColor
    }
    func accessibilityLabel(_ context: ToolbarContext) -> String {
        if let custom = context.annotation.customColor {
            return "取色（\(custom.hexString)）"
        }
        return "取色"
    }
    func width(_ context: ToolbarContext) -> CGFloat { ToolbarStyle.swatchWidth }

    func draw(in frame: CGRect, context: ToolbarContext, state: ToolbarRenderState) {
        // 有自定义颜色时画圆角方形色块（彩虹边框），否则画吸管图标
        if let custom = context.annotation.customColor {
            let size: CGFloat = 20
            let corner: CGFloat = 5
            let rect = CGRect(x: frame.midX - size / 2, y: frame.midY - size / 2, width: size, height: size)
            let path = NSBezierPath(roundedRect: rect, xRadius: corner, yRadius: corner)
            NSColor(srgbRed: custom.r, green: custom.g, blue: custom.b, alpha: 1).setFill()
            path.fill()
            // 彩虹边框表示"自定义取色" —— 环形路径 + 渐变填充
            let outer = NSBezierPath(roundedRect: rect.insetBy(dx: -2.5, dy: -2.5), xRadius: corner + 2, yRadius: corner + 2)
            let inner = NSBezierPath(roundedRect: rect, xRadius: corner, yRadius: corner)
            let ring = NSBezierPath()
            ring.append(outer)
            ring.append(inner)
            ring.windingRule = .evenOdd
            let colors: [NSColor] = [
                NSColor(srgbRed: 1, green: 0.3, blue: 0.3, alpha: 1),
                NSColor(srgbRed: 1, green: 0.8, blue: 0.2, alpha: 1),
                NSColor(srgbRed: 0.3, green: 1, blue: 0.4, alpha: 1),
                NSColor(srgbRed: 0.3, green: 0.6, blue: 1, alpha: 1),
                NSColor(srgbRed: 0.8, green: 0.4, blue: 1, alpha: 1),
            ]
            if let gradient = NSGradient(colors: colors) {
                gradient.draw(in: ring, relativeCenterPosition: .zero)
            }
        } else {
            ToolbarStyle.drawCenteredSymbol("eyedropper", in: frame)
        }
    }

    func activate(_ context: ToolbarContext) {
        if context.annotation.isPickingColor {
            // 再点一次退出取色
            context.annotation.isPickingColor = false
        } else {
            context.annotation.beginColorPicking()
        }
    }
}

/// 线宽控件（PixPin 风格：胶囊容器 + 横线粗细随档位 + 下拉箭头）。
/// 可拖动实时调档位，点击胶囊跳到对应档位。
struct WidthSliderControl: ToolbarControl {
    static let controlID = "widthSlider"
    private static let capsuleInset: CGFloat = 6

    var id: String { Self.controlID }
    var scopes: Set<ActionScope> { [.capture, .pinned] }
    var group: ToolbarGroup { .style }
    var order: Int { 100 }

    var supportsDrag: Bool { true }

    func isVisible(_ context: ToolbarContext) -> Bool {
        context.annotation.styleAxes.contains(.width)
    }
    func accessibilityLabel(_ context: ToolbarContext) -> String {
        let value = context.annotation.currentStyle.value(for: .width)
        return "线宽 \(Int(value))"
    }
    func width(_ context: ToolbarContext) -> CGFloat { 70 }

    func draw(in frame: CGRect, context: ToolbarContext, state: ToolbarRenderState) {
        let steps = ToolStyleAxis.width.steps
        let cur = context.annotation.styleIndex(for: .width)
        let value = steps.indices.contains(cur) ? steps[cur] : steps[steps.count / 2]

        // 胶囊容器
        let capRect = CGRect(
            x: frame.minX + Self.capsuleInset,
            y: frame.midY - 13,
            width: frame.width - Self.capsuleInset * 2,
            height: 26
        )
        let capPath = NSBezierPath(roundedRect: capRect, xRadius: 13, yRadius: 13)
        NSColor.black.withAlphaComponent(0.45).setFill()
        capPath.fill()

        // 数值（和字号胶囊一致）
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let text = "\(Int(value))" as NSString
        let bounds = text.size(withAttributes: attrs)
        text.draw(
            at: NSPoint(x: capRect.midX - bounds.width / 2 - 4, y: capRect.midY - bounds.height / 2),
            withAttributes: attrs
        )

        // 下拉箭头（chevron.down）
        if let chevron = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil) {
            let config = NSImage.SymbolConfiguration(pointSize: 7, weight: .regular)
            let sized = chevron.withSymbolConfiguration(config) ?? chevron
            let img = NSImage(size: sized.size)
            img.lockFocus()
            sized.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
            NSColor.white.withAlphaComponent(0.6).set()
            NSRect(origin: .zero, size: sized.size).fill(using: .sourceAtop)
            img.unlockFocus()
            img.draw(in: CGRect(
                x: capRect.maxX - 16,
                y: capRect.midY - img.size.height / 2,
                width: img.size.width,
                height: img.size.height
            ))
        }
    }

    /// 点击 = 跳到对应档位（按位置）。
    func activate(_ context: ToolbarContext) {
        // 没有位置信息，步进 +1
        let steps = ToolStyleAxis.width.steps
        let cur = context.annotation.styleIndex(for: .width)
        let next = (cur + 1) % steps.count
        context.annotation.setStyleIndex(next, for: .width)
        context.annotation.applyStyleToSelection(.width)
    }

    func drag(_ context: ToolbarContext, local: CGPoint, frame: CGRect) -> Bool {
        let steps = ToolStyleAxis.width.steps
        // 横线区域：capRect.minX + 12 到 capRect.maxX - 20
        let capRect = CGRect(
            x: frame.minX + Self.capsuleInset,
            y: frame.midY - 13,
            width: frame.width - Self.capsuleInset * 2,
            height: 26
        )
        let lineLeft = capRect.minX + 12
        let lineRight = capRect.maxX - 20
        let trackWidth = lineRight - lineLeft
        guard trackWidth > 0 else { return false }
        let relativeX = local.x - lineLeft
        let progress = max(0, min(1, relativeX / trackWidth))
        let index = Int(round(progress * CGFloat(steps.count - 1)))
        let clamped = max(0, min(index, steps.count - 1))
        if clamped != context.annotation.styleIndex(for: .width) {
            context.annotation.setStyleIndex(clamped, for: .width)
            context.annotation.applyStyleToSelection(.width)
        }
        return true
    }
}

/// 字号胶囊（PixPin 风格：胶囊容器 + 数值 + 下拉箭头）。
/// 可拖动实时调档位，点击胶囊跳到对应档位。
struct FontSizeCapsuleControl: ToolbarControl {
    static let controlID = "fontSizeCapsule"
    private static let capsuleInset: CGFloat = 6

    var id: String { Self.controlID }
    var scopes: Set<ActionScope> { [.capture, .pinned] }
    var group: ToolbarGroup { .style }
    var order: Int { 200 }

    var supportsDrag: Bool { true }

    func isVisible(_ context: ToolbarContext) -> Bool {
        context.annotation.styleAxes.contains(.fontSize)
    }
    func accessibilityLabel(_ context: ToolbarContext) -> String {
        let value = context.annotation.currentStyle.value(for: .fontSize)
        return "字号 \(Int(value))"
    }
    func width(_ context: ToolbarContext) -> CGFloat { 70 }

    func draw(in frame: CGRect, context: ToolbarContext, state: ToolbarRenderState) {
        let steps = ToolStyleAxis.fontSize.steps
        let cur = context.annotation.styleIndex(for: .fontSize)
        let value = steps.indices.contains(cur) ? steps[cur] : steps[steps.count / 2]

        // 胶囊容器
        let capRect = CGRect(
            x: frame.minX + Self.capsuleInset,
            y: frame.midY - 13,
            width: frame.width - Self.capsuleInset * 2,
            height: 26
        )
        let capPath = NSBezierPath(roundedRect: capRect, xRadius: 13, yRadius: 13)
        NSColor.black.withAlphaComponent(0.45).setFill()
        capPath.fill()

        // 数值
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let text = "\(Int(value))" as NSString
        let bounds = text.size(withAttributes: attrs)
        text.draw(
            at: NSPoint(x: capRect.midX - bounds.width / 2 - 4, y: capRect.midY - bounds.height / 2),
            withAttributes: attrs
        )

        // 下拉箭头
        if let chevron = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil) {
            let config = NSImage.SymbolConfiguration(pointSize: 7, weight: .regular)
            let sized = chevron.withSymbolConfiguration(config) ?? chevron
            let img = NSImage(size: sized.size)
            img.lockFocus()
            sized.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
            NSColor.white.withAlphaComponent(0.6).set()
            NSRect(origin: .zero, size: sized.size).fill(using: .sourceAtop)
            img.unlockFocus()
            img.draw(in: CGRect(
                x: capRect.maxX - 14,
                y: capRect.midY - img.size.height / 2,
                width: img.size.width,
                height: img.size.height
            ))
        }
    }

    func activate(_ context: ToolbarContext) {
        let steps = ToolStyleAxis.fontSize.steps
        let cur = context.annotation.styleIndex(for: .fontSize)
        let next = (cur + 1) % steps.count
        context.annotation.setStyleIndex(next, for: .fontSize)
        context.annotation.applyStyleToSelection(.fontSize)
    }

    func drag(_ context: ToolbarContext, local: CGPoint, frame: CGRect) -> Bool {
        let steps = ToolStyleAxis.fontSize.steps
        let capRect = CGRect(
            x: frame.minX + Self.capsuleInset,
            y: frame.midY - 13,
            width: frame.width - Self.capsuleInset * 2,
            height: 26
        )
        let trackWidth = capRect.width - 20
        guard trackWidth > 0 else { return false }
        let relativeX = local.x - capRect.minX - 10
        let progress = max(0, min(1, relativeX / trackWidth))
        let index = Int(round(progress * CGFloat(steps.count - 1)))
        let clamped = max(0, min(index, steps.count - 1))
        if clamped != context.annotation.styleIndex(for: .fontSize) {
            context.annotation.setStyleIndex(clamped, for: .fontSize)
            context.annotation.applyStyleToSelection(.fontSize)
        }
        return true
    }
}

/// 数值型样式轴的档位控件（透明度 / 颗粒 / 压暗 / 箭头头 / 填充 / 单位）。
///
/// 一根轴多档，登记处按 `ToolStyleAxis` × 档位注册一遍；**只有当前工具声明了
/// 这根轴时才出现**。width 轴由 `WidthSliderControl` 接管，fontSize 由 `FontSizeCapsuleControl` 接管。
struct ToolParamControl: ToolbarControl {
    let axis: ToolStyleAxis
    let index: Int

    var id: String { "param.\(axis.rawValue).\(index)" }
    var scopes: Set<ActionScope> { [.capture, .pinned] }
    var group: ToolbarGroup { .style }
    var order: Int { axis.order + index }

    /// 每根轴只显示当前档位一个控件（PixPin 式数值显示）。
    func isVisible(_ context: ToolbarContext) -> Bool {
        guard context.annotation.styleAxes.contains(axis) else { return false }
        return context.annotation.styleIndex(for: axis) == index
    }
    func isSelected(_ context: ToolbarContext) -> Bool {
        context.annotation.styleIndex(for: axis) == index
    }
    func accessibilityLabel(_ context: ToolbarContext) -> String {
        let steps = axis.steps
        guard steps.indices.contains(index) else { return axis.title }
        return "\(axis.title) \(Int(steps[index]))"
    }
    func width(_ context: ToolbarContext) -> CGFloat { 28 }

    func draw(in frame: CGRect, context: ToolbarContext, state: ToolbarRenderState) {
        axis.descriptor.toolbarDraw?(frame, index)
    }

    /// 点击 = 步进 +1（到顶回到底），滚轮 ±1 档。
    func activate(_ context: ToolbarContext) {
        let steps = axis.steps
        let cur = context.annotation.styleIndex(for: axis)
        let next = (cur + 1) % steps.count
        context.annotation.setStyleIndex(next, for: axis)
        context.annotation.applyStyleToSelection(axis)
    }
}

// MARK: - 文字样式开关（粗体 / 斜体）

/// 粗体开关（B）。只在文字工具激活时出现。
struct BoldControl: ToolbarControl {
    static let controlID = "textBold"

    var id: String { Self.controlID }
    var scopes: Set<ActionScope> { [.capture, .pinned] }
    var group: ToolbarGroup { .style }
    var order: Int { 900 }

    func isVisible(_ context: ToolbarContext) -> Bool {
        context.annotation.styleAxes.contains(.bold)
    }
    func isSelected(_ context: ToolbarContext) -> Bool {
        context.annotation.styleIndex(for: .bold) == 1
    }
    func accessibilityLabel(_ context: ToolbarContext) -> String { "粗体" }

    func draw(in frame: CGRect, context: ToolbarContext, state: ToolbarRenderState) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .bold),
            .foregroundColor: state.isSelected ? NSColor.white : NSColor.white.withAlphaComponent(0.5)
        ]
        let text = "B" as NSString
        let bounds = text.size(withAttributes: attrs)
        text.draw(
            at: NSPoint(x: frame.midX - bounds.width / 2, y: frame.midY - bounds.height / 2),
            withAttributes: attrs
        )
    }

    func activate(_ context: ToolbarContext) {
        let cur = context.annotation.styleIndex(for: .bold)
        context.annotation.setStyleIndex(cur == 1 ? 0 : 1, for: .bold)
        context.annotation.applyStyleToSelection(.bold)
    }
}

/// 斜体开关（I）。只在文字工具激活时出现。
struct ItalicControl: ToolbarControl {
    static let controlID = "textItalic"

    var id: String { Self.controlID }
    var scopes: Set<ActionScope> { [.capture, .pinned] }
    var group: ToolbarGroup { .style }
    var order: Int { 910 }

    func isVisible(_ context: ToolbarContext) -> Bool {
        context.annotation.styleAxes.contains(.italic)
    }
    func isSelected(_ context: ToolbarContext) -> Bool {
        context.annotation.styleIndex(for: .italic) == 1
    }
    func accessibilityLabel(_ context: ToolbarContext) -> String { "斜体" }

    func draw(in frame: CGRect, context: ToolbarContext, state: ToolbarRenderState) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFontManager.shared.convert(
                NSFont.systemFont(ofSize: 13, weight: .medium),
                toHaveTrait: .italicFontMask
            ),
            .foregroundColor: state.isSelected ? NSColor.white : NSColor.white.withAlphaComponent(0.5)
        ]
        let text = "I" as NSString
        let bounds = text.size(withAttributes: attrs)
        text.draw(
            at: NSPoint(x: frame.midX - bounds.width / 2, y: frame.midY - bounds.height / 2),
            withAttributes: attrs
        )
    }

    func activate(_ context: ToolbarContext) {
        let cur = context.annotation.styleIndex(for: .italic)
        context.annotation.setStyleIndex(cur == 1 ? 0 : 1, for: .italic)
        context.annotation.applyStyleToSelection(.italic)
    }
}

// MARK: - 效果开关（美化 / 带壳 / 水印 / 捕获信息）

/// 效果层的开关控件。效果不是画笔而是**输出选项** —— 点一下经
/// `AnnotationState.toggleEffect` 加/删一层对应的效果层（单例语义、可撤销），
/// 参数与元数据由描述符（`EffectRegistry`）在开关那一刻烤入。
/// 控件本身是参数化的，登记处按 `EffectRegistry.displayOrdered` 循环注册；
/// 样式子选项（预设 / 模式 / 壳样式 / 字段勾选）在图库编辑器的效果面板里。
struct EffectToggleControl: ToolbarControl {
    let id: String
    /// 排在颜色（0..）和粗细（100..）之后（300..）。
    let order: Int
    let symbolName: String
    let kind: Layer.Kind
    let title: String

    /// 从注册表描述符构造。新增效果只需在 `EffectRegistry` 声明一处，
    /// 工具条与编辑器面板自动跟随，无需在此追加硬编码注册行。
    init(descriptor: EffectDescriptor) {
        self.id = descriptor.id
        self.order = descriptor.toolbarOrder
        self.symbolName = descriptor.symbolName
        self.kind = descriptor.kind
        self.title = descriptor.panelTitle
    }

    init(id: String, order: Int, symbolName: String, kind: Layer.Kind) {
        self.id = id
        self.order = order
        self.symbolName = symbolName
        self.kind = kind
        self.title = id
    }

    /// 只在钉图上出现：截图工具条为保持精简撤掉了输出开关 ——
    /// 截图阶段要效果的用户可以钉图后再开，或去图库编辑器调。
    /// 「导出自动加水印」在协调器里，不走这个开关，截图阶段照常生效。
    var scopes: Set<ActionScope> { [.pinned] }
    var group: ToolbarGroup { .actions }

    /// 已开启的效果才显示开关（可快捷关闭）；未开启时不占位，保持工具条紧凑。
    func isVisible(_ context: ToolbarContext) -> Bool {
        context.annotation.hasEffect(kind)
    }

    func isSelected(_ context: ToolbarContext) -> Bool {
        context.annotation.hasEffect(kind)
    }
    func accessibilityLabel(_ context: ToolbarContext) -> String { title }

    func draw(in frame: CGRect, context: ToolbarContext, state: ToolbarRenderState) {
        ToolbarStyle.drawCenteredSymbol(symbolName, in: frame)
    }

    func activate(_ context: ToolbarContext) {
        context.annotation.toggleEffect(kind)
    }
}

