import SwiftUI

// MARK: - 上传

struct UploadSettings: View {
    @ObservedObject var settings: AppSettings

    @State private var isTesting = false
    @State private var testResult: String?
    @State private var testSucceeded = false

    var body: some View {
        Form {
            Section {
                TextField("接口地址", text: $settings.upload.uploadEndpoint, prompt: Text("https://example.com/upload"))
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                TextField("文件字段名", text: $settings.upload.uploadFieldName, prompt: Text("file"))
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
            } header: {
                Text("接口")
            } footer: {
                Text("multipart/form-data POST。兼容 PicGo / uPic 自定义 API、Cloudflare Workers 自建、Chevereto 等；不支持 S3 直传签名。")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Section {
                TextEditor(text: $settings.upload.uploadHeaders)
                    .font(.system(.caption, design: .monospaced))
                    .frame(height: 60)
                    .autocorrectionDisabled()
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(DS.focusRingIdle)
                    )
            } header: {
                Text("请求头")
            } footer: {
                Text("每行一条，如 Authorization: Bearer xxx。明文保存在本机偏好设置里。")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Section("响应与链接") {
                TextField("链接路径", text: $settings.upload.uploadResponsePath, prompt: Text("如 data.url，留空则整个响应体即链接"))
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                Picker("剪贴板格式", selection: $settings.upload.uploadLinkFormat) {
                    ForEach(AppSettings.UploadLinkFormat.allCases) { format in
                        Text(format.title).tag(format)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section {
                HStack {
                    Button(isTesting ? "上传中…" : "测试上传") { runTest() }
                        .disabled(isTesting || settings.upload.uploadEndpoint.trimmingCharacters(in: .whitespaces).isEmpty)
                    if isTesting {
                        ProgressView().controlSize(.small)
                    }
                }
                if let testResult {
                    Text(testResult)
                        .font(.caption)
                        .foregroundStyle(testSucceeded ? Color.green : Color.red)
                        .textSelection(.enabled)
                }
            } header: {
                Text("测试")
            } footer: {
                Text("会往图床传一张 1×1 像素的 PNG 验证配置。")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .formStyle(.grouped)
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
                    png: png, filename: "macshot-test.png", config: config
                )
                testResult = "成功：\(link)"
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
