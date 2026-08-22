import CoreGraphics
import Foundation
import XCTest
@testable import IndexApp

final class OpenAICompatibleSelectionAIProviderTests: XCTestCase {
    func testConfigurationBuildsChatCompletionsEndpoint() {
        let base = OpenAICompatibleSelectionAIConfiguration(
            baseURL: " https://ai-api.wxyhgk.com/v1/ ",
            model: "gpt-5.6-luna"
        )
        XCTAssertEqual(base.responseURL?.absoluteString, "https://ai-api.wxyhgk.com/v1/chat/completions")

        // 用户直接填了完整端点
        let endpoint = OpenAICompatibleSelectionAIConfiguration(
            baseURL: "https://example.com/v1/chat/completions",
            model: "model"
        )
        XCTAssertEqual(endpoint.responseURL?.absoluteString, "https://example.com/v1/chat/completions")

        // http 也支持（本地模型服务器）
        let insecure = OpenAICompatibleSelectionAIConfiguration(
            baseURL: "http://1.94.67.196:1561/v1",
            model: "model"
        )
        XCTAssertEqual(insecure.responseURL?.absoluteString, "http://1.94.67.196:1561/v1/chat/completions")
    }

    func testRequestUsesChatCompletionsFormatAndDoesNotPutKeyInBody() throws {
        let provider = OpenAICompatibleSelectionAIProvider(
            configuration: .init(
                baseURL: "https://ai-api.wxyhgk.com/v1",
                model: " gpt-5.6-luna "
            ),
            credentialStore: FixedSelectionAIKeyStore(key: "test-secret")
        )
        let request = SelectionAIRequest(
            task: .translate(targetLanguage: "zh-Hans"),
            input: .init(image: try makeImage(), recognizedText: "source"),
            instruction: "保留术语"
        )

        let urlRequest = try provider.makeURLRequest(for: request)
        XCTAssertEqual(urlRequest.url?.absoluteString, "https://ai-api.wxyhgk.com/v1/chat/completions")
        XCTAssertEqual(urlRequest.httpMethod, "POST")
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "Authorization"), "Bearer test-secret")

        let bodyData = try XCTUnwrap(urlRequest.httpBody)
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
        )
        XCTAssertEqual(body["model"] as? String, "gpt-5.6-luna")
        XCTAssertEqual(body["max_tokens"] as? Int, 2_048)
        XCTAssertFalse(String(decoding: bodyData, as: UTF8.self).contains("test-secret"))

        // messages 数组：system + user
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0]["role"] as? String, "system")
        XCTAssertEqual(messages[1]["role"] as? String, "user")

        // user message 的 content 数组包含 text + image_url
        let content = try XCTUnwrap(messages[1]["content"] as? [[String: Any]])
        let imageBlock = try XCTUnwrap(content.first { $0["type"] as? String == "image_url" })
        let imageUrl = try XCTUnwrap(imageBlock["image_url"] as? [String: Any])
        XCTAssertTrue((imageUrl["url"] as? String)?.hasPrefix("data:image/png;base64,") == true)
    }

    func testRequestDownsamplesLargeSelectionBeforeBase64Encoding() throws {
        let provider = OpenAICompatibleSelectionAIProvider(
            configuration: .init(baseURL: "https://example.com/v1", model: "model"),
            credentialStore: FixedSelectionAIKeyStore(key: "test-secret")
        )
        let urlRequest = try provider.makeURLRequest(for: SelectionAIRequest(
            task: .explain,
            input: .init(image: try makeImage(width: 2_200, height: 100))
        ))
        let bodyData = try XCTUnwrap(urlRequest.httpBody)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        let userMsg = try XCTUnwrap(messages.first { $0["role"] as? String == "user" })
        let content = try XCTUnwrap(userMsg["content"] as? [[String: Any]])
        let imageBlock = try XCTUnwrap(content.first { $0["type"] as? String == "image_url" })
        let imageUrl = try XCTUnwrap(imageBlock["image_url"] as? [String: Any])
        let dataURL = try XCTUnwrap(imageUrl["url"] as? String)
        let separator = try XCTUnwrap(dataURL.firstIndex(of: ","))
        let imageData = try XCTUnwrap(Data(base64Encoded: String(dataURL[dataURL.index(after: separator)...])))
        let decoded = try XCTUnwrap(ImageCodec.load(from: imageData))

        XCTAssertEqual(decoded.width, 2_048)
        XCTAssertEqual(decoded.height, 93)
    }

    func testMissingKeyFailsBeforeNetworkRequest() throws {
        let provider = OpenAICompatibleSelectionAIProvider(
            configuration: .init(baseURL: "https://example.com/v1", model: "model"),
            credentialStore: FixedSelectionAIKeyStore(key: nil)
        )

        XCTAssertThrowsError(try provider.makeURLRequest(for: SelectionAIRequest(
            task: .explain,
            input: .init(image: try makeImage())
        ))) { error in
            guard case OpenAICompatibleSelectionAIError.missingAPIKey = error else {
                return XCTFail("应返回 missingAPIKey，实际为 \(error)")
            }
        }
    }

    func testChatCompletionsEnvelopeMapsToStructuredTableResult() throws {
        let payload = """
        {
          "kind": "extractTable",
          "primary": "| A | B |",
          "markdown": "| A | B |",
          "csv": "A,B",
          "source_language": null,
          "target_language": null
        }
        """
        // Chat Completions 响应格式
        let envelope: [String: Any] = [
            "choices": [[
                "message": [
                    "role": "assistant",
                    "content": payload
                ]
            ]]
        ]
        let data = try JSONSerialization.data(withJSONObject: envelope)

        let result = try OpenAICompatibleSelectionAIProvider.parseResult(
            from: data,
            task: .extractTable
        )
        XCTAssertEqual(
            result,
            .table(.init(markdown: "| A | B |", csv: "A,B"))
        )
    }

    func testChatCompletionsEnvelopeStripsMarkdownFence() throws {
        let payload = """
        ```json
        {"kind":"explain","primary":"hello","markdown":"hello","csv":null,"source_language":null,"target_language":null}
        ```
        """
        let envelope: [String: Any] = [
            "choices": [[
                "message": [
                    "role": "assistant",
                    "content": payload
                ]
            ]]
        ]
        let data = try JSONSerialization.data(withJSONObject: envelope)

        let result = try OpenAICompatibleSelectionAIProvider.parseResult(
            from: data,
            task: .explain
        )
        XCTAssertEqual(result, .explanation(markdown: "hello"))
    }

    private func makeImage(width: Int = 2, height: Int = 2) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }
}

private struct FixedSelectionAIKeyStore: SelectionAIAPIKeyStoring {
    let key: String?

    func loadAPIKey() throws -> String? { key }
    func saveAPIKey(_ apiKey: String) throws {}
    func deleteAPIKey() throws {}
}
