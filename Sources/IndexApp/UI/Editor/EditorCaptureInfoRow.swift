import SwiftUI

// MARK: - 编辑器效果面板「捕获信息」行

/// 效果面板里的「捕获信息」一行：开关 + 三个字段勾选（App / 网址 / 时间）。
/// 样式对齐图库 inspector 的分组卡片（quaternary 底 + DS.radiusCard 圆角 +
/// caption.semibold 组题，同 `TagSection`）。
///
/// **自包含**：不依赖 EditorView 的任何内部状态 ——
///   · 元数据（App 名+版本 / 网址 / 捕获时刻）在 `toggleEffect` 那一刻从
///     `AnnotationState.effectContext` 烤入（编辑器在装载时注入 shot 的归因，
///     见 `EditorView.load`），时机与覆盖层 / 钉图一致
///   · 所有改动经 `toggleEffect` / `setCaptureInfoFields` 走撤销栈，
///     然后回调 `onChange` 让宿主自增 tick 驱动重绘
struct EditorCaptureInfoRow: View {
    let annotation: AnnotationState
    /// 每次状态机变更后调用；宿主在这里 tick（编辑器的 `annotationTick += 1`）。
    let onChange: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.s2) {
            HStack {
                Text("捕获信息")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Toggle("捕获信息", isOn: enabledBinding)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
            }

            if annotation.hasEffect(.captureInfo) {
                HStack(spacing: DS.s3) {
                    ForEach(CaptureInfoSpec.Field.allCases, id: \.rawValue) { field in
                        Toggle(field.displayName, isOn: fieldBinding(field))
                            .toggleStyle(.checkbox)
                            .font(.caption)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(DS.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.insetSurface, in: RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous))
    }

    // MARK: 绑定

    /// 总开关。元数据值在 `toggleEffect` 那一刻从注入上下文烤进参数 JSON，
    /// 之后图层自带数据，关掉再开会重新烤（取舍同 frame）。
    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { annotation.hasEffect(.captureInfo) },
            set: { _ in
                annotation.toggleEffect(.captureInfo)
                onChange()
            }
        )
    }

    /// 单个字段的勾选。写回时按 `Field.allCases` 归一顺序 ——
    /// 勾选先后不影响信息栏的排版次序（App 恒在左、网址居中、时间在右）。
    private func fieldBinding(_ field: CaptureInfoSpec.Field) -> Binding<Bool> {
        Binding(
            get: { annotation.captureInfoFields?.contains(field) ?? false },
            set: { on in
                guard let current = annotation.captureInfoFields else { return }
                var selected = Set(current)
                if on { selected.insert(field) } else { selected.remove(field) }
                let ordered = CaptureInfoSpec.Field.allCases.filter(selected.contains)
                if annotation.setCaptureInfoFields(ordered) { onChange() }
            }
        )
    }
}
