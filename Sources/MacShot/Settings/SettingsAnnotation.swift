import SwiftUI

// MARK: - 标注

struct AnnotationSettings: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section("默认颜色") {
                HStack(spacing: 10) {
                    ForEach(AnnotationState.palette.indices, id: \.self) { index in
                        let color = AnnotationState.palette[index]
                        Circle()
                            .fill(Color(.sRGB, red: color.r, green: color.g, blue: color.b))
                            .frame(width: 22, height: 22)
                            .overlay {
                                Circle().strokeBorder(
                                    settings.annotationStyle.defaultColorIndex == index
                                        ? DS.accent : DS.focusRingIdle,
                                    lineWidth: settings.annotationStyle.defaultColorIndex == index ? 3 : 1
                                )
                            }
                            .onTapGesture { settings.annotationStyle.defaultColorIndex = index }
                    }
                    Spacer()
                }
            }

            Section("默认粗细") {
                Picker("", selection: $settings.annotationStyle.defaultWidthIndex) {
                    ForEach(AnnotationState.widths.indices, id: \.self) { index in
                        Text("\(Int(AnnotationState.widths[index])) pt").tag(index)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            Section {
                TextField("默认文案", text: $settings.annotationStyle.watermarkText, prompt: Text("如 @your-name"))
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                Picker("默认位置", selection: $settings.annotationStyle.watermarkMode) {
                    ForEach(WatermarkMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                HStack {
                    Slider(value: $settings.annotationStyle.watermarkAlpha, in: 0.1...0.8) {
                        Text("透明度")
                    }
                    Text("\(Int(settings.annotationStyle.watermarkAlpha * 100))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: 36, alignment: .trailing)
                }
                Toggle("导出自动加水印", isOn: $settings.annotationStyle.autoWatermark)
            } header: {
                Text("水印")
            } footer: {
                Text("水印是一个图层：进修订链、可撤销、可在图库编辑器里删除。自动水印只作用于新截图，文案为空时不生效；工具条/编辑器里的手动开关不受这一项影响。")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Section {
                Text("原图永远不会被修改。标注以图层形式存成修订，每次编辑都是追加一条记录，可以无限回溯。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("关于标注")
            }
        }
        .formStyle(.grouped)
    }
}
