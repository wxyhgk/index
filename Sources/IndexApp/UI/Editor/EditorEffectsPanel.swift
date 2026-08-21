import SwiftUI

// MARK: - 效果面板（编辑器右侧「效果」tab）
//
// 四个效果层（美化 / 水印 / 外壳 / 捕获信息）的开关与样式子选项。
// 从 `EditorView` 拆出来的第一块 —— 它的独立性最好：只读写标注状态机上的效果层，
// 不碰画布几何、不碰缩放、不碰修订链。
//
// 效果本身的契约在 `Annotation/EffectLayer.swift`（描述符 + 注册表），
// **新增效果只需在 `EffectRegistry` 追加一个描述符**，工具条与本面板均按
// `EffectRegistry.displayOrdered` 循环生成，种类列表不再硬编码；
// 四宿主（覆盖层/钉图/编辑器/图库）的开关与展示因此自动跟随。
// 子选项（预设 / 模式 / 壳样式 / 字段勾选）的具体控件仍按 kind 分发，
// 但分发点收敛于 `effectOptions(for:)` 一处，不在面板与工具条两处镜像。
struct EditorEffectsPanel: View {

    @ObservedObject var model: EditorModel

    private var annotation: AnnotationState { model.annotation }

    var body: some View { effectsPanel }

    /// 效果 tab：每个效果一行分组卡片（开关 + 展开的样式子选项）。
    /// 行样式对齐图库 inspector：quaternary 底 + DS.radiusCard + caption.semibold 组题。
    /// 卡片由注册表驱动，新增效果自动出现，无需在此追加硬编码行。
    private var effectsPanel: some View {
        ScrollView {
            VStack(spacing: DS.s3) {
                ForEach(EffectRegistry.displayOrdered, id: \.kind) { descriptor in
                    effectCard(descriptor: descriptor)
                }
            }
            .padding(DS.s3)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// 通用卡片：标题与开关由描述符提供，内容按 kind 分发到 `effectOptions`。
    private func effectCard(descriptor: EffectDescriptor) -> some View {
        effectCard(
            descriptor.panelTitle,
            isOn: annotation.hasEffect(descriptor.kind),
            toggle: { annotation.toggleEffect(descriptor.kind) }
        ) {
            effectOptions(for: descriptor)
        }
    }

    /// 子选项按 kind 分发。新增带选项的效果在此追加一个 case 即可，
    /// 种类列表本身仍由注册表驱动，不与工具条重复硬编码。
    @ViewBuilder
    private func effectOptions(for descriptor: EffectDescriptor) -> some View {
        switch descriptor.kind {
        case .backdrop:
            HStack(spacing: DS.s2) {
                ForEach(BackdropPreset.allCases, id: \.rawValue) { preset in
                    backdropSwatch(preset)
                }
            }
        case .watermark:
            Picker("水印位置", selection: Binding(
                get: { annotation.watermarkMode ?? .corner },
                set: { mode in annotation.setWatermarkMode(mode) }
            )) {
                ForEach(WatermarkMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        case .frame:
            Picker("壳样式", selection: Binding(
                get: { annotation.frameStyle ?? .macos },
                set: { style in annotation.setFrameStyle(style) }
            )) {
                ForEach(FrameSpec.Style.allCases, id: \.rawValue) { style in
                    Text(style.displayName).tag(style)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        case .captureInfo:
            HStack(spacing: DS.s3) {
                ForEach(CaptureInfoSpec.Field.allCases, id: \.rawValue) { field in
                    Toggle(field.displayName, isOn: fieldBinding(field))
                        .toggleStyle(.checkbox)
                        .font(.caption)
                }
                Spacer(minLength: 0)
            }
        default:
            EmptyView()
        }
    }

    /// 分组卡片骨架：组题 + 右侧开关，开着时展开子选项。
    private func effectCard(
        _ title: String,
        isOn: Bool,
        toggle: @escaping () -> Void,
        @ViewBuilder options: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: DS.s2) {
            HStack {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Toggle(title, isOn: Binding(get: { isOn }, set: { _ in toggle() }))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
            }
            if isOn {
                options()
            }
        }
        .padding(DS.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.insetSurface, in: RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous))
    }

    /// 背景预设小色块：渐变预设画渐变、纯色预设画灰块，选中态描 accent 边。
    private func backdropSwatch(_ preset: BackdropPreset) -> some View {
        let selected = annotation.backdropPresetID == preset.rawValue
        return Button {
            annotation.setBackdropPreset(preset.rawValue)        } label: {
            RoundedRectangle(cornerRadius: DS.radiusSmall)
                .fill(swatchGradient(preset))
                .frame(width: 40, height: 26)
                // 透明档画一条斜杠示意「这里什么都没有」——
                // 光靠一块浅灰跟 solid 预设分不出来。
                .overlay {
                    if preset == .transparent {
                        Path { path in
                            path.move(to: CGPoint(x: 6, y: 20))
                            path.addLine(to: CGPoint(x: 34, y: 6))
                        }
                        .stroke(DS.borderStrong, lineWidth: 1.5)
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: DS.radiusSmall)
                        .strokeBorder(
                            selected ? DS.accent : DS.borderDefault,
                            lineWidth: selected ? 2 : 1
                        )
                )
        }
        .buttonStyle(.plain)
        .help(preset.displayName)
    }

    private func swatchGradient(_ preset: BackdropPreset) -> LinearGradient {
        guard let (a, b) = preset.gradientColors else {
            // 透明档示意为很淡的底（配一条斜杠）；solid 导出时用图层自身颜色，示意为中性灰。
            let white = preset == .transparent ? 0.85 : 0.4
            return LinearGradient(
                colors: [Color(.sRGB, white: white, opacity: preset == .transparent ? 0.25 : 1)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        }
        return LinearGradient(
            colors: [Color(cgColor: a), Color(cgColor: b)],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
    }

    /// 捕获信息字段勾选（原 `EditorCaptureInfoRow` 的字段行，本面板内收敛）。
    private func fieldBinding(_ field: CaptureInfoSpec.Field) -> Binding<Bool> {
        Binding(
            get: { annotation.captureInfoFields?.contains(field) ?? false },
            set: { on in
                guard let current = annotation.captureInfoFields else { return }
                var selected = Set(current)
                if on { selected.insert(field) } else { selected.remove(field) }
                let ordered = CaptureInfoSpec.Field.allCases.filter(selected.contains)
                _ = annotation.setCaptureInfoFields(ordered)
            }
        )
    }
}
