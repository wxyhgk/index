import CoreGraphics
import SwiftUI

struct SelectionAISettings: View {
    @ObservedObject var settings: AppSettings

    @State private var apiKey = ""
    @State private var hasStoredKey = false
    @State private var isTesting = false
    @State private var statusText: String?
    @State private var statusIsError = false

    var body: some View {
        Form {
            Section("服务") {
                TextField("Base URL", text: $settings.intelligence.selectionAIBaseURL)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()

                TextField("模型", text: $settings.intelligence.selectionAIModel)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()

                HStack {
                    Spacer()
                    Button("恢复默认") {
                        settings.intelligence.selectionAIBaseURL = IntelligencePrefs.defaults.selectionAIBaseURL
                        settings.intelligence.selectionAIModel = IntelligencePrefs.defaults.selectionAIModel
                    }
                    .controlSize(.small)
                }

                Text("使用 OpenAI-compatible Responses API。请求只包含你再次框选的局部图片；服务地址必须是 HTTPS。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("API Key") {
                SecureField(
                    hasStoredKey ? "已保存在 macOS 钥匙串；输入新值可替换" : "粘贴 API Key",
                    text: $apiKey
                )
                .textFieldStyle(.roundedBorder)

                HStack(spacing: 8) {
                    Label(
                        hasStoredKey ? "已安全保存" : "尚未配置",
                        systemImage: hasStoredKey ? "checkmark.shield.fill" : "key"
                    )
                    .font(.caption)
                    .foregroundStyle(hasStoredKey ? .green : .secondary)

                    Spacer()

                    if hasStoredKey {
                        Button("移除") { removeKey() }
                            .controlSize(.small)
                    }
                    Button(hasStoredKey ? "替换" : "保存") { saveKey() }
                        .controlSize(.small)
                        .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                Text("密钥不会写入项目、UserDefaults 或日志，只保存在当前 Mac 的钥匙串中。界面不会回显已经保存的值。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("验证") {
                HStack(spacing: 10) {
                    Button {
                        Task { await testConnection() }
                    } label: {
                        if isTesting {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("测试中…")
                            }
                        } else {
                            Text("测试连接")
                        }
                    }
                    .disabled(isTesting || !hasStoredKey)

                    if let statusText {
                        Text(statusText)
                            .font(.caption)
                            .foregroundStyle(statusIsError ? .red : .green)
                            .lineLimit(2)
                    }
                }

                Text("测试会向当前服务发送一张不含用户内容的 8×8 白色图片，以验证鉴权、图像输入和结构化输出。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("使用") {
                Text("普通截图确认范围后，点击 Tool Palette 的“AI 选区”，再次框选局部内容，然后选择解释、翻译、公式或表格。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { refreshKeyStatus() }
    }

    private func refreshKeyStatus() {
        do {
            hasStoredKey = try MacSelectionAIKeychain.shared.loadAPIKey() != nil
        } catch {
            hasStoredKey = false
            setStatus(error.localizedDescription, isError: true)
        }
    }

    private func saveKey() {
        do {
            try MacSelectionAIKeychain.shared.saveAPIKey(apiKey)
            apiKey = ""
            hasStoredKey = true
            setStatus("已保存", isError: false)
        } catch {
            setStatus(error.localizedDescription, isError: true)
        }
    }

    private func removeKey() {
        do {
            try MacSelectionAIKeychain.shared.deleteAPIKey()
            apiKey = ""
            hasStoredKey = false
            setStatus("已移除", isError: false)
        } catch {
            setStatus(error.localizedDescription, isError: true)
        }
    }

    private func testConnection() async {
        isTesting = true
        defer { isTesting = false }
        do {
            let provider = OpenAICompatibleSelectionAIProvider(
                configuration: .init(
                    baseURL: settings.intelligence.selectionAIBaseURL,
                    model: settings.intelligence.selectionAIModel
                )
            )
            let result = try await provider.perform(SelectionAIRequest(
                task: .explain,
                input: SelectionAIInput(image: Self.testImage())
            ))
            guard result.kind == .explain else {
                throw SelectionAIError.responseKindMismatch(
                    expected: .explain,
                    actual: result.kind
                )
            }
            setStatus("连接成功", isError: false)
        } catch {
            setStatus(error.localizedDescription, isError: true)
        }
    }

    private func setStatus(_ text: String, isError: Bool) {
        statusText = text
        statusIsError = isError
    }

    private static func testImage() -> CGImage {
        let context = CGContext(
            data: nil,
            width: 8,
            height: 8,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        return context.makeImage()!
    }
}
