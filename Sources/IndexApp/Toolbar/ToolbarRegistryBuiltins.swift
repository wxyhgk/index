import AppKit

// ============================================================
// MARK: - 内置工具条控件登记
//
// 按固定顺序注册所有控件到 ToolbarRegistry。
// ============================================================

// MARK: - 登记

extension ToolbarRegistry {

    /// 常驻工具条的工具。椭圆、高亮、聚光灯、测量、序号只保留快捷键
    /// （O / H / S / M / N）—— 截图标注里「指出、框住、写字、打码」是绝对主力，
    /// 快捷键激活的非常驻工具会临时露面（见 `ToolControl.isVisible`）。
    ///
    /// 常驻与否现在是各工具描述符自己声明的（`isPinnedToBar`），
    /// 这里只是转发 —— 加一个工具不必回到这个文件改数组。
    static var pinnedTools: [AnnotationTool] { ToolRegistry.pinnedTools }

    static func registerBuiltins(into registry: ToolbarRegistry) {
        // 顺序、常驻与否全部来自登记处（`BuiltinTools.all`）。
        // 鼠标（指针）不占按钮：不选任何工具 = 指针模式，快捷键 V 也能进入。
        for (index, descriptor) in ToolRegistry.descriptors.enumerated() {
            registry.register(ToolControl(
                tool: descriptor.tool,
                order: index + 1,
                isPinnedToBar: descriptor.isPinnedToBar
            ))
        }

        registry.register(AnnotationEntryControl())
        registry.register(SelectionAIControl())
        // PixPin：选中矩形后下行左侧出矩形/圆形两格变体
        registry.register(ShapeVariantControl(tool: .rect))
        registry.register(ShapeVariantControl(tool: .ellipse))
        AnnotationState.palette.indices.forEach { registry.register(ColorControl(index: $0)) }
        registry.register(ColorPickerControl())
        // 线宽滑杆 + 字号胶囊（PixPin 式可拖动）
        registry.register(WidthSliderControl())
        registry.register(FontSizeCapsuleControl())
        // 文字样式开关（粗体 / 斜体）
        registry.register(BoldControl())
        registry.register(ItalicControl())
        // 数值轴 × 多档全部注册；哪些真正出现在条上由当前工具的描述符决定
        // （`ToolParamControl.isVisible` → `ToolRegistry.descriptor(for:).axes`）。
        // width 由 WidthSliderControl、fontSize 由 FontSizeCapsuleControl、
        // bold/italic 由 BoldControl/ItalicControl 接管，这里跳过。
        for descriptor in ToolStyleAxisDescriptor.all where descriptor.axis != .color && descriptor.axis != .width && descriptor.axis != .fontSize && descriptor.axis != .bold && descriptor.axis != .italic {
            descriptor.steps.indices.forEach { registry.register(ToolParamControl(axis: descriptor.axis, index: $0)) }
        }
        // 效果开关统一由 `EffectRegistry` 驱动，新增效果只需在注册表声明一处。
        // 截图阶段常驻的「带壳」入口；效果开关本身仍只给钉图。
        registry.register(FrameCaptureControl())
        for descriptor in EffectRegistry.displayOrdered {
            registry.register(EffectToggleControl(descriptor: descriptor))
        }
        registry.register(UndoControl())
        registry.register(RedoControl())
        registry.register(MoleculeSourceControl())
    }
}
