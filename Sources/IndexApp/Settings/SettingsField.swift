import SwiftUI

// MARK: - 设置页通用防抖输入组件
//
// 直接绑定 @Published 的 TextField 每敲一个字符都触发 didSet → defaults.set
// → @Published 通知 → 整个 TabView 重算。这里用 @State 本地缓存 + 500ms 防抖，
// 输入时只更新本地状态，停顿后才写 settings。

struct DebouncedTextField: View {
    let title: String
    let placeholder: String?
    let initialValue: String
    let monospaced: Bool
    let onCommit: (String) -> Void

    @State private var text: String = ""
    @State private var isLoaded = false
    @State private var saveTask: Task<Void, Never>?

    var body: some View {
        TextField(title, text: $text, prompt: placeholder.map { Text($0) })
            .textFieldStyle(.roundedBorder)
            .autocorrectionDisabled()
            .font(monospaced ? .system(.body, design: .monospaced) : .body)
            .onAppear {
                if !isLoaded {
                    text = initialValue
                    isLoaded = true
                }
            }
            .onChange(of: text) { _, _ in
                saveTask?.cancel()
                saveTask = Task {
                    try? await Task.sleep(for: .milliseconds(500))
                    guard !Task.isCancelled else { return }
                    await MainActor.run { onCommit(text) }
                }
            }
    }
}

struct DebouncedTextEditor: View {
    let initialValue: String
    let onCommit: (String) -> Void

    @State private var text: String = ""
    @State private var isLoaded = false
    @State private var saveTask: Task<Void, Never>?

    var body: some View {
        TextEditor(text: $text)
            .font(.system(.caption, design: .monospaced))
            .frame(height: 60)
            .autocorrectionDisabled()
            .overlay(
                RoundedRectangle(cornerRadius: DS.radiusSmall)
                    .strokeBorder(DS.focusRingIdle)
            )
            .onAppear {
                if !isLoaded {
                    text = initialValue
                    isLoaded = true
                }
            }
            .onChange(of: text) { _, _ in
                saveTask?.cancel()
                saveTask = Task {
                    try? await Task.sleep(for: .milliseconds(500))
                    guard !Task.isCancelled else { return }
                    await MainActor.run { onCommit(text) }
                }
            }
    }
}

struct DebouncedSecureField: View {
    let placeholder: String
    let initialValue: String
    let onCommit: (String) -> Void

    @State private var text: String = ""
    @State private var isLoaded = false
    @State private var saveTask: Task<Void, Never>?

    var body: some View {
        SecureField(placeholder, text: $text)
            .textFieldStyle(.roundedBorder)
            .font(.system(.body, design: .monospaced))
            .onAppear {
                if !isLoaded {
                    text = initialValue
                    isLoaded = true
                }
            }
            .onChange(of: text) { _, _ in
                saveTask?.cancel()
                saveTask = Task {
                    try? await Task.sleep(for: .milliseconds(500))
                    guard !Task.isCancelled else { return }
                    await MainActor.run { onCommit(text) }
                }
            }
    }
}
