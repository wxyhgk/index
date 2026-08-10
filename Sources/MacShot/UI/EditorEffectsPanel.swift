import SwiftUI

// MARK: - 效果面板（编辑器右侧「效果」tab）
//
// 四个效果层（美化 / 水印 / 外壳 / 捕获信息）的开关与样式子选项。
// 从 `EditorView` 拆出来的第一块 —— 它的独立性最好：只读写标注状态机上的效果层，
// 不碰画布几何、不碰缩放、不碰修订链。
//
// 效果本身的契约在 `Annotation/EffectLayer.swift`（描述符 + 注册表），
// 这里只是它的一套界面：**加一个效果不该改这个文件**，
// 但四个效果各自的子选项（预设 / 模式 / 壳样式 / 字段勾选）确实是各写各的。
struct EditorEffectsPanel: View {

    @ObservedObject var model: EditorModel

    private var annotation: AnnotationState { model.annotation }

    var body: some View { effectsPanel }

    /// 效果 tab：每个效果一行分组卡片（开关 + 展开的样式子选项）。
    /// 行样式对齐图库 inspector：quaternary 底 + DS.radiusCard + caption.semibold 组题。
    private var effectsPanel: some View {
        ScrollView {
            VStack(spacing: DS.s3) {
                backdropCard
                watermarkCard
                frameCard
                EditorCaptureInfoRow(annotation: annotation) {                }
            }
            .padding(DS.s3)
        }
        .frame(maxHeight: .infinity, alignment: .top)
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

    /// 美化行。backdrop 只影响导出/复制/保存的成品 ——
    /// 画布预览刻意不变（见 `AnnotationRenderer` 的说明），开关表达状态。
    /// 预设色块点选即换（`setBackdropPreset`），作为一条可撤销的 style 记录。
    private var backdropCard: some View {
        effectCard("美化", isOn: annotation.hasEffect(.backdrop), toggle: {
            annotation.toggleEffect(.backdrop)        }) {
            HStack(spacing: DS.s2) {
                ForEach(BackdropPreset.allCases, id: \.rawValue) { preset in
                    backdropSwatch(preset)
                }
            }
        }
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

    /// 水印行。参数（设置里的文案/模式/透明度，没配文案时的 "MacShot" 兜底）
    /// 都在描述符 `EffectRegistry.watermark` 里 —— 工具条开关、自动水印共用同一份。
    /// 和美化不同，水印会画进画布预览 —— 它影响构图判断。
    /// 位置三选走 `setWatermarkMode`，作为一条可撤销的 style 记录。
    private var watermarkCard: some View {
        effectCard("水印", isOn: annotation.hasEffect(.watermark), toggle: {
            annotation.toggleEffect(.watermark)        }) {
            Picker("水印位置", selection: Binding(
                get: { annotation.watermarkMode ?? .corner },
                set: { mode in
                    annotation.setWatermarkMode(mode)                }
            )) {
                ForEach(WatermarkMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    /// 外壳行。frame 只影响导出/复制/保存的成品，画布预览刻意不变（同美化的取舍）。
    /// 开壳时把 shot 的真实窗口标题 / 网址烤进壳的参数 JSON（见 `load` 的注入上下文）；
    /// 样式二选走 `setFrameStyle`，作为一条可撤销的 style 记录。
    private var frameCard: some View {
        effectCard("外壳", isOn: annotation.hasEffect(.frame), toggle: {
            annotation.toggleEffect(.frame)        }) {
            Picker("壳样式", selection: Binding(
                get: { annotation.frameStyle ?? .macos },
                set: { style in
                    annotation.setFrameStyle(style)                }
            )) {
                ForEach(FrameSpec.Style.allCases, id: \.rawValue) { style in
                    Text(style.displayName).tag(style)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }
}
