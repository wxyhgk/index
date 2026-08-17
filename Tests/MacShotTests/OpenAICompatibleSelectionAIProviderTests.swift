import CoreGraphics
import Foundation
import XCTest
@testable import MacShot

final class OpenAICompatibleSelectionAIProviderTests: XCTestCase {
    func testConfigurationNormalizesResponsesEndpointAndRejectsHTTP() {
        let base = OpenAICompatibleSelectionAIConfiguration(
            baseURL: " https://ai-api.wxyhgk.com/v1/ ",
            model: "gpt-5.6-luna"
        )
        XCTAssertEqual(base.responseURL?.absoluteString, "https://ai-api.wxyhgk.com/v1/responses")

        let endpoint = OpenAICompatibleSelectionAIConfiguration(
            baseURL: "https://example.com/v1/responses",
            model: "model"
        )
        XCTAssertEqual(endpoint.responseURL?.absoluteString, "https://example.com/v1/responses")

        let insecure = OpenAICompatibleSelectionAIConfiguration(
            baseURL: "http://example.com/v1",
            model: "model"
        )
        XCTAssertNil(insecure.responseURL)
    }

    func testRequestUsesImageInputStructuredOutputAndDoesNotPutKeyInBody() throws {
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
        XCTAssertEqual(urlRequest.url?.absoluteString, "https://ai-api.wxyhgk.com/v1/responses")
        XCTAssertEqual(urlRequest.httpMethod, "POST")
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "Authorization"), "Bearer test-secret")

        let bodyData = try XCTUnwrap(urlRequest.httpBody)
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
        )
        XCTAssertEqual(body["model"] as? String, "gpt-5.6-luna")
        XCTAssertEqual(body["store"] as? Bool, false)
        XCTAssertEqual(body["max_output_tokens"] as? Int, 2_048)
        XCTAssertFalse(String(decoding: bodyData, as: UTF8.self).contains("test-secret"))

        let input = try XCTUnwrap(body["input"] as? [[String: Any]])
        let content = try XCTUnwrap(input.first?["content"] as? [[String: Any]])
        let imageBlock = try XCTUnwrap(content.first { $0["type"] as? String == "input_image" })
        XCTAssertTrue((imageBlock["image_url"] as? String)?.hasPrefix("data:image/png;base64,") == true)
        XCTAssertEqual(imageBlock["detail"] as? String, "high")

        let text = try XCTUnwrap(body["text"] as? [String: Any])
        let format = try XCTUnwrap(text["format"] as? [String: Any])
        XCTAssertEqual(format["type"] as? String, "json_schema")
        XCTAssertEqual(format["strict"] as? Bool, true)
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
        let input = try XCTUnwrap(body["input"] as? [[String: Any]])
        let content = try XCTUnwrap(input.first?["content"] as? [[String: Any]])
        let imageBlock = try XCTUnwrap(content.first { $0["type"] as? String == "input_image" })
        let dataURL = try XCTUnwrap(imageBlock["image_url"] as? String)
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

    func testResponsesEnvelopeMapsToStructuredTableResult() throws {
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
        let envelope: [String: Any] = [
            "output": [[
                "type": "message",
                "content": [["type": "output_text", "text": payload]]
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
