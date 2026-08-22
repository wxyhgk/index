import SwiftUI

struct AnnotationSettings: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        SettingsPage {
            // 颜色 + 粗细：小卡片并排
            ToggleCardGrid {
                MiniCard("颜色", icon: "paintpalette") {
                    HStack(spacing: DS.s2) {
                        ForEach(AnnotationState.palette.indices, id: \.self) { i in
                            let c = AnnotationState.palette[i]
                            Circle()
                                .fill(Color(.sRGB, red: c.r, green: c.g, blue: c.b))
                                .frame(width: 20, height: 20)
                                .overlay {
                                    Circle().strokeBorder(
                                        settings.annotationStyle.defaultColorIndex == i ? DS.accent : DS.focusRingIdle,
                                        lineWidth: settings.annotationStyle.defaultColorIndex == i ? 2.5 : 1
                                    )
                                }
                                .onTapGesture { settings.annotationStyle.defaultColorIndex = i }
                        }
                    }
                }

                MiniCard("粗细", icon: "line.diagonal") {
                    Picker("", selection: $settings.annotationStyle.defaultWidthIndex) {
                        ForEach(AnnotationState.widths.indices, id: \.self) { i in
                            Text("\(Int(AnnotationState.widths[i]))pt").tag(i)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
            }

            // 水印：内容多，大卡片
            SettingsCard("水印", icon: "textformat") {
                DebouncedTextField(
                    title: "文案",
                    placeholder: "@your-name",
                    initialValue: settings.annotationStyle.watermarkText,
                    monospaced: false
                ) { settings.annotationStyle.watermarkText = $0 }

                Picker("位置", selection: $settings.annotationStyle.watermarkMode) {
                    ForEach(WatermarkMode.allCases) { m in
                        Text(m.displayName).tag(m)
                    }
                }
                .pickerStyle(.segmented)

                HStack(spacing: DS.s2) {
                    Slider(value: $settings.annotationStyle.watermarkAlpha, in: 0.1...0.8)
                    Text("\(Int(settings.annotationStyle.watermarkAlpha * 100))%")
                        .font(.system(size: DS.font10)).foregroundStyle(.secondary).monospacedDigit()
                        .frame(width: 32, alignment: .trailing)
                }

                SettingsRow("自动加水印", icon: "wand.and.stars") {
                    Toggle("", isOn: $settings.annotationStyle.autoWatermark)
                        .labelsHidden().toggleStyle(.switch)
                }
            }
        }
    }
}
