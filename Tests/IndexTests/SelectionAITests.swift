import CoreGraphics
import XCTest
@testable import IndexApp

final class SelectionAITests: XCTestCase {
    func testTaskAndStructuredResultKindsStayAligned() {
        XCTAssertEqual(SelectionAITask.explain.kind, .explain)
        XCTAssertEqual(SelectionAITask.translate(targetLanguage: "zh-Hans").kind, .translate)
        XCTAssertEqual(SelectionAITask.formulaToLaTeX.kind, .formulaToLaTeX)
        XCTAssertEqual(SelectionAITask.extractTable.kind, .extractTable)

        XCTAssertEqual(SelectionAIResult.explanation(markdown: "说明").kind, .explain)
        XCTAssertEqual(
            SelectionAIResult.translation(.init(
                text: "结果",
                sourceLanguage: "en",
                targetLanguage: "zh-Hans"
            )).kind,
            .translate
        )
        XCTAssertEqual(SelectionAIResult.formula(.init(latex: "E=mc^2")).kind, .formulaToLaTeX)
        XCTAssertEqual(
            SelectionAIResult.table(.init(markdown: "| A |", csv: "A")).kind,
            .extractTable
        )
    }

    func testRequestCarriesOnlyCroppedPixelsAndOptionalRecognizedText() throws {
        let image = try makeImage(width: 12, height: 7)
        let input = SelectionAIInput(image: image, recognizedText: "local OCR")
        let request = SelectionAIRequest(
            task: .translate(targetLanguage: "zh-Hans"),
            input: input,
            instruction: "保留术语"
        )

        XCTAssertEqual(request.input.pixelSize, CGSize(width: 12, height: 7))
        XCTAssertEqual(request.input.recognizedText, "local OCR")
        XCTAssertEqual(request.instruction, "保留术语")
    }

    func testUnavailableProviderFailsWithoutTouchingPixels() async throws {
        let executor = SelectionAIExecutor(provider: UnavailableSelectionAIProvider())
        let request = try makeRequest(task: .explain)

        do {
            _ = try await executor.execute(request)
            XCTFail("未配置 Provider 时不得执行")
        } catch let error as SelectionAIError {
            XCTAssertEqual(error, .providerUnavailable(providerID: "unconfigured"))
        }
        let state = await executor.state
        XCTAssertEqual(state, .idle)
    }

    func testExecutorReturnsTraceableStructuredResponse() async throws {
        let result = SelectionAIResult.formula(.init(latex: "\\Delta E_{ST}"))
        let provider = SelectionAIProviderProbe(result: result)
        let executor = SelectionAIExecutor(provider: provider)
        let request = try makeRequest(task: .formulaToLaTeX)

        let response = try await executor.execute(request)

        XCTAssertEqual(response.requestID, request.id)
        XCTAssertEqual(response.task, request.task)
        XCTAssertEqual(response.providerID, "test.selection-ai")
        XCTAssertEqual(response.result, result)
        let startedCount = await provider.startedCount()
        let finalState = await executor.state
        XCTAssertEqual(startedCount, 1)
        XCTAssertEqual(finalState, .idle)
    }

    func testExecutorRejectsUnsupportedTaskBeforeCallingProvider() async throws {
        let provider = SelectionAIProviderProbe(
            supportedTasks: [.explain],
            result: .explanation(markdown: "ok")
        )
        let executor = SelectionAIExecutor(provider: provider)
        let request = try makeRequest(task: .extractTable)

        do {
            _ = try await executor.execute(request)
            XCTFail("不支持的任务不得进入 Provider")
        } catch let error as SelectionAIError {
            XCTAssertEqual(error, .unsupportedTask(.extractTable))
        }
        let startedCount = await provider.startedCount()
        XCTAssertEqual(startedCount, 0)
    }

    func testExecutorIsStrictSingleFlight() async throws {
        let provider = SelectionAIProviderProbe(
            result: .explanation(markdown: "ok"),
            blocksUntilReleased: true
        )
        let executor = SelectionAIExecutor(provider: provider)
        let firstRequest = try makeRequest(task: .explain)
        let first = Task { try await executor.execute(firstRequest) }
        let didStart = await waitUntil { await provider.startedCount() == 1 }
        let runningState = await executor.state
        XCTAssertTrue(didStart)
        XCTAssertEqual(runningState, .running(requestID: firstRequest.id, task: .explain))

        do {
            _ = try await executor.execute(try makeRequest(task: .explain))
            XCTFail("运行中不得扇出第二个请求")
        } catch let error as SelectionAIError {
            XCTAssertEqual(error, .busy)
        }

        await provider.release()
        _ = try await first.value
        let startedCount = await provider.startedCount()
        let finalState = await executor.state
        XCTAssertEqual(startedCount, 1)
        XCTAssertEqual(finalState, .idle)
    }

    func testCancellationPropagatesAndGateReopensAfterProviderFinishes() async throws {
        let provider = SelectionAIProviderProbe(
            result: .explanation(markdown: "late"),
            blocksUntilReleased: true
        )
        let executor = SelectionAIExecutor(provider: provider)
        let request = try makeRequest(task: .explain)
        let running = Task { try await executor.execute(request) }
        let didStart = await waitUntil { await provider.startedCount() == 1 }
        XCTAssertTrue(didStart)

        await executor.cancelCurrent()
        do {
            _ = try await running.value
            XCTFail("取消后的迟到结果不得发布")
        } catch is CancellationError {
            // expected
        }

        let cancelledCount = await provider.cancelledCount()
        let finalState = await executor.state
        XCTAssertEqual(cancelledCount, 1)
        XCTAssertEqual(finalState, .idle)
    }

    func testNonCooperativeProviderKeepsGateClosedUntilItReallyFinishes() async throws {
        let provider = NonCooperativeSelectionAIProviderProbe()
        let executor = SelectionAIExecutor(provider: provider)
        let request = try makeRequest(task: .explain)
        let running = Task { try await executor.execute(request) }
        let didStart = await waitUntil { await provider.startedCount() == 1 }
        XCTAssertTrue(didStart)

        await executor.cancelCurrent()
        let stateAfterCancel = await executor.state
        XCTAssertEqual(stateAfterCancel, .running(requestID: request.id, task: .explain))

        do {
            _ = try await executor.execute(try makeRequest(task: .explain))
            XCTFail("底层请求未结束时不得重新打开执行门")
        } catch let error as SelectionAIError {
            XCTAssertEqual(error, .busy)
        }

        await provider.release()
        do {
            _ = try await running.value
            XCTFail("取消后的迟到结果不得发布")
        } catch is CancellationError {
            // expected
        }
        let finalState = await executor.state
        XCTAssertEqual(finalState, .idle)
    }

    func testMismatchedProviderResultIsRejected() async throws {
        let provider = SelectionAIProviderProbe(result: .explanation(markdown: "wrong"))
        let executor = SelectionAIExecutor(provider: provider)

        do {
            _ = try await executor.execute(try makeRequest(task: .formulaToLaTeX))
            XCTFail("不能把解释文本冒充 LaTeX 结果交给 UI")
        } catch let error as SelectionAIError {
            XCTAssertEqual(
                error,
                .responseKindMismatch(expected: .formulaToLaTeX, actual: .explain)
            )
        }
        let finalState = await executor.state
        XCTAssertEqual(finalState, .idle)
    }

    func testStructuredResultsProduceCompleteExportDocuments() {
        let explanation = response(
            task: .explain,
            result: .explanation(markdown: "**结论**")
        ).document
        XCTAssertEqual(explanation.preview, "**结论**")
        XCTAssertEqual(explanation.exports, [
            .init(format: .markdown, text: "**结论**")
        ])

        let translation = response(
            task: .translate(targetLanguage: "zh-Hans"),
            result: .translation(.init(
                text: "翻译结果",
                sourceLanguage: "en",
                targetLanguage: "zh-Hans"
            ))
        ).document
        XCTAssertEqual(translation.exports, [
            .init(format: .plainText, text: "翻译结果")
        ])

        let formula = response(
            task: .formulaToLaTeX,
            result: .formula(.init(latex: "\\Delta E_{ST}"))
        ).document
        XCTAssertEqual(formula.exports, [
            .init(format: .latex, text: "\\Delta E_{ST}")
        ])

        let table = response(
            task: .extractTable,
            result: .table(.init(markdown: "| A |", csv: "A"))
        ).document
        XCTAssertEqual(table.preview, "| A |")
        XCTAssertEqual(table.exports, [
            .init(format: .markdown, text: "| A |"),
            .init(format: .csv, text: "A")
        ])
    }

    private func response(
        task: SelectionAITask,
        result: SelectionAIResult
    ) -> SelectionAIResponse {
        SelectionAIResponse(
            requestID: UUID(),
            task: task,
            providerID: "test.selection-ai",
            result: result
        )
    }

    private func makeRequest(task: SelectionAITask) throws -> SelectionAIRequest {
        SelectionAIRequest(task: task, input: SelectionAIInput(image: try makeImage()))
    }

    private func makeImage(width: Int = 8, height: Int = 8) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        return try XCTUnwrap(context.makeImage())
    }

    private func waitUntil(
        attempts: Int = 100,
        condition: @escaping () async -> Bool
    ) async -> Bool {
        for _ in 0..<attempts {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        return false
    }
}

private actor SelectionAIProviderProbe: SelectionAIProvider {
    nonisolated let id = "test.selection-ai"
    nonisolated let isAvailable = true
    nonisolated let supportedTasks: Set<SelectionAITaskKind>

    private let result: SelectionAIResult
    private let blocksUntilReleased: Bool
    private var released = false
    private var starts = 0
    private var cancellations = 0

    init(
        supportedTasks: Set<SelectionAITaskKind> = Set(SelectionAITaskKind.allCases),
        result: SelectionAIResult,
        blocksUntilReleased: Bool = false
    ) {
        self.supportedTasks = supportedTasks
        self.result = result
        self.blocksUntilReleased = blocksUntilReleased
    }

    func perform(_ request: SelectionAIRequest) async throws -> SelectionAIResult {
        starts += 1
        do {
            while blocksUntilReleased, !released {
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            try Task.checkCancellation()
            return result
        } catch {
            if error is CancellationError { cancellations += 1 }
            throw error
        }
    }

    func release() {
        released = true
    }

    func startedCount() -> Int { starts }
    func cancelledCount() -> Int { cancellations }
}

/// 模拟一个底层 SDK：Task.cancel() 不能终止其系统/网络调用，只能等真实回调。
private actor NonCooperativeSelectionAIProviderProbe: SelectionAIProvider {
    nonisolated let id = "test.non-cooperative-selection-ai"
    nonisolated let supportedTasks = Set(SelectionAITaskKind.allCases)

    private var starts = 0
    private var continuation: CheckedContinuation<Void, Never>?

    func perform(_ request: SelectionAIRequest) async throws -> SelectionAIResult {
        starts += 1
        await withCheckedContinuation { continuation = $0 }
        return .explanation(markdown: "late")
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }

    func startedCount() -> Int { starts }
}
