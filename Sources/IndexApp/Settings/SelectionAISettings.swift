import CoreGraphics
import SwiftUI

struct SelectionAISettings: View {
    @ObservedObject var settings: AppSettings

    @State private var apiKey = ""
    @State private var hasStoredKey = false
    @State private var showReplaceField = false
    @State private var isTesting = false
    @State private var statusText: String?
    @State private var statusIsError = false

    var body: some View {
        SettingsPage {
            SettingsCard("服务", icon: "server.rack") {
                DebouncedTextField(
                    title: "Base URL",
                    placeholder: "https://api.openai.com/v1",
                    initialValue: settings.intelligence.selectionAIBaseURL,
                    monospaced: true
                ) { settings.intelligence.selectionAIBaseURL = $0 }

                DebouncedTextField(
                    title: "模型",
                    placeholder: "gpt-4o",
                    initialValue: settings.intelligence.selectionAIModel,
                    monospaced: true
                ) { settings.intelligence.selectionAIModel = $0 }

                HStack {
                    Spacer()
                    Button("恢复默认") {
                        settings.intelligence.selectionAIBaseURL = IntelligencePrefs.defaults.selectionAIBaseURL
                        settings.intelligence.selectionAIModel = IntelligencePrefs.defaults.selectionAIModel
                    }
                    .controlSize(.mini)
                }
            }

            SettingsCard("API Key", icon: "key") {
                if hasStoredKey {
                    HStack(spacing: DS.s2) {
                        Image(systemName: "checkmark.shield.fill")
                            .font(.system(size: DS.font12)).foregroundStyle(.green)
                        Spacer()
                        Button("替换") { showReplaceField = true }
                            .controlSize(.mini)
                        Button("移除") { removeKey() }
                            .controlSize(.mini)
                    }
                    if showReplaceField {
                        HStack(spacing: DS.s2) {
                            SecureField("粘贴新 Key", text: $apiKey)
                                .textFieldStyle(.roundedBorder)
                            Button("保存") { saveKey(); showReplaceField = false }
                                .controlSize(.mini)
                                .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                } else {
                    HStack(spacing: DS.s2) {
                        SecureField("粘贴 API Key", text: $apiKey)
                            .textFieldStyle(.roundedBorder)
                        Button("保存") { saveKey() }
                            .controlSize(.mini)
                            .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }

            SettingsCard("验证", icon: "checkmark.seal") {
                HStack(spacing: DS.s3) {
                    Button {
                        Task { await testConnection() }
                    } label: {
                        if isTesting {
                            HStack(spacing: DS.s2) {
                                ProgressView().controlSize(.mini)
                                Text("测试中…")
                            }
                        } else {
                            Text("测试连接")
                        }
                    }
                    .disabled(isTesting || !hasStoredKey)

                    if let statusText {
                        Text(statusText)
                            .font(.system(size: DS.font11))
                            .foregroundStyle(statusIsError ? .red : .green)
                    }
                }
            }
        }
        .onAppear { refreshKeyStatus() }
    }

    private func refreshKeyStatus() {
        do {
            hasStoredKey = try MacSelectionAIKeychain.shared.loadAPIKey() != nil
        } catch {
            hasStoredKey = false
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
                    expected: .explain, actual: result.kind
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
            data: nil, width: 8, height: 8,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        return context.makeImage()!
    }
}
