import SwiftUI

struct UploadSettings: View {
    @ObservedObject var settings: AppSettings

    @State private var isTesting = false
    @State private var testResult: String?
    @State private var testSucceeded = false

    var body: some View {
        SettingsPage {
            SettingsCard("接口", icon: "network") {
                DebouncedTextField(
                    title: "地址",
                    placeholder: "https://example.com/upload",
                    initialValue: settings.upload.uploadEndpoint,
                    monospaced: true
                ) { settings.upload.uploadEndpoint = $0 }

                DebouncedTextField(
                    title: "字段名",
                    placeholder: "file",
                    initialValue: settings.upload.uploadFieldName,
                    monospaced: true
                ) { settings.upload.uploadFieldName = $0 }

                DebouncedTextEditor(
                    initialValue: settings.upload.uploadHeaders
                ) { settings.upload.uploadHeaders = $0 }

                DebouncedTextField(
                    title: "链接路径",
                    placeholder: "data.url",
                    initialValue: settings.upload.uploadResponsePath,
                    monospaced: true
                ) { settings.upload.uploadResponsePath = $0 }

                Picker("剪贴板格式", selection: $settings.upload.uploadLinkFormat) {
                    ForEach(AppSettings.UploadLinkFormat.allCases) { f in
                        Text(f.title).tag(f)
                    }
                }
                .pickerStyle(.segmented)
            }

            MiniCard("测试", icon: "checkmark.circle") {
                HStack(spacing: DS.s3) {
                    Button(isTesting ? "上传中…" : "测试上传") { runTest() }
                        .disabled(isTesting || settings.upload.uploadEndpoint.isEmpty)
                    if isTesting { ProgressView().controlSize(.mini) }
                }
                if let testResult {
                    HStack(spacing: DS.s2) {
                        Image(systemName: testSucceeded ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .font(.system(size: DS.font12))
                            .foregroundStyle(testSucceeded ? .green : .red)
                        Text(testResult)
                            .font(.system(size: DS.font11))
                            .foregroundStyle(testSucceeded ? .green : .red)
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }

    private func runTest() {
        guard let png = Self.makeTestPNG() else {
            testResult = "生成测试图片失败"
            testSucceeded = false
            return
        }
        let config = UploadConfig(
            endpoint: settings.upload.uploadEndpoint,
            fieldName: settings.upload.uploadFieldName,
            headersText: settings.upload.uploadHeaders,
            responsePath: settings.upload.uploadResponsePath
        )
        isTesting = true
        testResult = nil
        Task {
            do {
                let link = try await ImageUploader.upload(
                    png: png, filename: "index-test.png", config: config
                )
                testResult = link
                testSucceeded = true
            } catch {
                testResult = error.localizedDescription
                testSucceeded = false
            }
            isTesting = false
        }
    }

    private static func makeTestPNG() -> Data? {
        guard let context = CGContext(
            data: nil, width: 1, height: 1,
            bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard let image = context.makeImage() else { return nil }
        return ImageCodec.pngData(from: image)
    }
}
