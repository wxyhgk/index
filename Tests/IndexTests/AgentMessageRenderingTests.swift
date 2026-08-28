import XCTest
@testable import IndexApp

final class AgentMessageRenderingTests: XCTestCase {
    func testLiveAndStoredMessagesUseTheSamePresentationShape() throws {
        let call = AgentMessage.ToolCallInfo(
            name: "search",
            args: #"{"query":"Index"}"#,
            status: .done,
            result: "1 result"
        )
        let live = AgentMessage(
            role: .assistant,
            text: "**完成**",
            toolCalls: [call]
        )
        let json = try XCTUnwrap(AgentToolCallCodec.encode(live.toolCalls))
        let stored = AgentMessageRecord(
            id: 1,
            conversationID: 2,
            role: "assistant",
            text: live.text,
            toolCallsJSON: json,
            createdAt: Date()
        )

        let livePresentation = AgentMessagePresentation(message: live)
        let storedPresentation = try XCTUnwrap(AgentMessagePresentation(record: stored))

        XCTAssertEqual(livePresentation.role, storedPresentation.role)
        XCTAssertEqual(livePresentation.text, storedPresentation.text)
        XCTAssertEqual(storedPresentation.toolCalls.count, 1)
        XCTAssertEqual(storedPresentation.toolCalls[0].name, call.name)
        XCTAssertEqual(storedPresentation.toolCalls[0].args, call.args)
        XCTAssertEqual(storedPresentation.toolCalls[0].status, call.status)
        XCTAssertEqual(storedPresentation.toolCalls[0].result, call.result)
    }

    func testInvalidToolJSONDoesNotHideAssistantText() throws {
        let record = AgentMessageRecord(
            id: 1,
            conversationID: 2,
            role: "assistant",
            text: "仍然显示",
            toolCallsJSON: "not-json",
            createdAt: Date()
        )

        let presentation = try XCTUnwrap(AgentMessagePresentation(record: record))

        XCTAssertEqual(presentation.text, "仍然显示")
        XCTAssertTrue(presentation.toolCalls.isEmpty)
    }

    func testUnknownStoredRoleIsNotRenderedAsAnotherRole() {
        let record = AgentMessageRecord(
            id: 1,
            conversationID: 2,
            role: "system",
            text: "hidden",
            toolCallsJSON: nil,
            createdAt: Date()
        )

        XCTAssertNil(AgentMessagePresentation(record: record))
    }
}
