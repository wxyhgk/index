import Foundation

// MARK: - 效果层（watermark / captureInfo / frame / backdrop）
//
// 四个效果层是「只影响导出成品」的单例图层：没有画布形体，不是拖出来的，
// 只有加/删两种操作。拆成独立文件后，主文件只留状态属性与造层入口。

extension AnnotationState {

    /// 某效果当前是否开启。工具条开关 / 效果面板的选中态看它。
    func hasEffect(_ kind: Layer.Kind) -> Bool {
        layers.elements.contains { $0.kind == kind }
    }

    /// 效果开关。效果层不是拖出来的图层，只有加/删两种操作：
    /// 没有则按描述符（`EffectRegistry`）造一层，参数与元数据在这一刻从
    /// `effectContext` 烤入；有则全部删掉。都走 `record` 保持可撤销；
    /// 同时只保留一层 —— 加之前先清干净（正常情况下最多一层）。
    @discardableResult
    func toggleEffect(_ kind: Layer.Kind) -> Bool {
        guard let descriptor = EffectRegistry.descriptor(for: kind) else { return false }
        endTextEditing()
        if hasEffect(kind) {
            while let index = layers.elements.firstIndex(where: { $0.kind == kind }) {
                let old = layers[index]
                history.record(.remove(old, index: index, preview: nil))
                layers.remove(id: old.id)
                if selectedID == old.id { selectedID = nil }
            }
            return false
        }
        var context = effectContext()
        context.pixelScale = pixelScale   // 渲染标度由状态机补充，宿主不用管。
        let layer = descriptor.makeLayer(context)
        layers.append(layer)
        history.record(.add(layer, preview: nil))
        return true
    }

    /// 某效果层当前的参数串（`Layer.text`）；未开启时 nil。
    private func effectText(_ kind: Layer.Kind) -> String? {
        layers.elements.last { $0.kind == kind }?.text
    }

    /// 替换某效果层的参数串，记一条 style 撤销记录。
    /// `transform` 拿旧参数串返回新的；返回 nil 表示无变化，不入栈。
    /// 未开启该效果时不做事。
    private func updateEffect(_ kind: Layer.Kind, transform: (String) -> String?) -> Bool {
        guard let index = layers.elements.firstIndex(where: { $0.kind == kind }),
              let newText = transform(layers[index].text),
              newText != layers[index].text else { return false }
        let before = layers[index]
        layers[index].text = newText
        history.record(.style(id: before.id, before: before, after: layers[index]))
        return true
    }

    // MARK: 效果参数的类型化读写（都是 effectText / updateEffect 的一行封装）

    /// 当前美化层的背景预设名；未开启时为 nil。
    var backdropPresetID: String? { effectText(.backdrop).map { BackdropSpec.parse($0).preset } }

    /// 当前水印的摆放模式；未开启时为 nil。
    var watermarkMode: WatermarkMode? {
        effectText(.watermark).flatMap { WatermarkSpec.decode($0)?.mode }
    }

    /// 当前壳的样式；未开启时为 nil。
    var frameStyle: FrameSpec.Style? {
        effectText(.frame).map { FrameSpec.parse($0).style }
    }

    /// 当前勾选要显示的字段；未开启时为 nil。
    var captureInfoFields: [CaptureInfoSpec.Field]? {
        effectText(.captureInfo).map { CaptureInfoSpec.parse($0).fields }
    }

    /// 替换美化层的背景预设。
    ///
    /// **只换 preset 一个字段**：`text` 里还装着阴影参数，
    /// 整条覆盖成预设名会把它们抹掉（旧实现就是这样，那时 text 里只有预设名）。
    @discardableResult
    func setBackdropPreset(_ presetID: String) -> Bool {
        updateEffect(.backdrop) { text in
            var spec = BackdropSpec.parse(text)
            guard spec.preset != presetID else { return nil }
            spec.preset = presetID
            return spec.json
        }
    }

    /// 替换水印的摆放模式。
    @discardableResult
    func setWatermarkMode(_ mode: WatermarkMode) -> Bool {
        updateEffect(.watermark) { text in
            guard var spec = WatermarkSpec.decode(text), spec.mode != mode else { return nil }
            spec.mode = mode
            return spec.encoded
        }
    }

    /// 切换壳样式（macOS 窗口 / 浏览器）。
    @discardableResult
    func setFrameStyle(_ style: FrameSpec.Style) -> Bool {
        updateEffect(.frame) { text in
            var spec = FrameSpec.parse(text)
            guard spec.style != style else { return nil }
            spec.style = style
            return spec.json
        }
    }

    /// 替换勾选字段。烤入的元数据值不动，只改显示哪些。
    @discardableResult
    func setCaptureInfoFields(_ fields: [CaptureInfoSpec.Field]) -> Bool {
        updateEffect(.captureInfo) { text in
            var spec = CaptureInfoSpec.parse(text)
            guard spec.fields != fields else { return nil }
            spec.fields = fields
            return spec.json
        }
    }
}