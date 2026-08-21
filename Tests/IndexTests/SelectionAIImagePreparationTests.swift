import CoreGraphics
import XCTest
@testable import IndexApp

final class SelectionAIImagePreparationTests: XCTestCase {
    func testTaskPoliciesPreserveMorePixelsForScientificExtraction() {
        let explain = SelectionAIRequestPolicy.policy(for: .explain)
        let translate = SelectionAIRequestPolicy.policy(for: .translate)
        let formula = SelectionAIRequestPolicy.policy(for: .formulaToLaTeX)
        let table = SelectionAIRequestPolicy.policy(for: .extractTable)

        XCTAssertLessThan(explain.maxPixelCount, translate.maxPixelCount)
        XCTAssertLessThan(translate.maxPixelCount, formula.maxPixelCount)
        XCTAssertLessThan(formula.maxPixelCount, table.maxPixelCount)
        XCTAssertEqual(formula.maxOutputTokens, 1_024)
        XCTAssertEqual(table.maxOutputTokens, 4_096)
    }

    func testTargetSizeUsesBothLongEdgeAndPixelBudgets() {
        XCTAssertEqual(
            SelectionAIImagePreprocessor.targetSize(
                width: 4_000,
                height: 3_000,
                maxLongEdge: 2_048,
                maxPixelCount: 3_000_000
            ),
            SelectionAIImageSize(width: 2_000, height: 1_500)
        )

        XCTAssertEqual(
            SelectionAIImagePreprocessor.targetSize(
                width: 3_000,
                height: 1_000,
                maxLongEdge: 2_048,
                maxPixelCount: 3_000_000
            ),
            SelectionAIImageSize(width: 2_048, height: 682)
        )
    }

    func testSmallImageIsNeverUpscaled() throws {
        let image = try makeImage(width: 320, height: 180)
        let prepared = try XCTUnwrap(SelectionAIImagePreprocessor.prepare(
            image,
            maxLongEdge: 2_048,
            maxPixelCount: 3_000_000
        ))

        XCTAssertEqual(prepared.width, 320)
        XCTAssertEqual(prepared.height, 180)
    }

    func testEncodedImageStaysInsideTaskBudget() throws {
        let image = try makeImage(width: 2_200, height: 100)
        let policy = SelectionAIRequestPolicy.policy(for: .explain)
        let encoded = try SelectionAIImageEncoder.encode(image, policy: policy)

        XCTAssertEqual(encoded.mimeType, "image/png")
        XCTAssertEqual(encoded.pixelSize, SelectionAIImageSize(width: 2_048, height: 93))
        XCTAssertLessThanOrEqual(encoded.data.count, policy.maxEncodedBytes)
    }

    private func makeImage(width: Int, height: Int) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }
}
