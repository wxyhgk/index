import XCTest
@testable import IndexApp

final class ScreenCaptureRequestGateTests: XCTestCase {

    func testOnlyOneCaptureSessionCanRunAtATime() throws {
        let gate = ScreenCaptureRequestGate()
        let session = try gate.beginSession()

        XCTAssertEqual(gate.status, .active(operation: nil))
        XCTAssertThrowsError(try gate.beginSession()) { error in
            XCTAssertEqual(
                error as? ScreenCaptureRequestGate.StartError,
                .active(operation: nil)
            )
        }

        gate.finishSession(session)
        XCTAssertEqual(gate.status, .idle)
    }

    func testNormalOperationsStayInsideOneSession() throws {
        let gate = ScreenCaptureRequestGate()
        let session = try gate.beginSession()
        let first = try XCTUnwrap(gate.beginOperation(in: session, name: "shareable-content"))

        XCTAssertEqual(gate.status, .active(operation: "shareable-content"))
        XCTAssertEqual(gate.finishOperation(first), .completed)
        XCTAssertEqual(gate.status, .active(operation: nil))

        let second = try XCTUnwrap(gate.beginOperation(in: session, name: "display:42"))
        XCTAssertEqual(gate.finishOperation(second), .completed)
        gate.finishSession(session)

        XCTAssertEqual(gate.status, .idle)
    }

    func testTimeoutQuarantinesUntilRealCallbackArrives() throws {
        let gate = ScreenCaptureRequestGate()
        let session = try gate.beginSession()
        let operation = try XCTUnwrap(
            gate.beginOperation(in: session, name: "shareable-content")
        )

        XCTAssertTrue(gate.timeOut(operation))
        gate.finishSession(session)
        XCTAssertEqual(gate.status, .quarantined(operation: "shareable-content"))
        XCTAssertThrowsError(try gate.beginSession()) { error in
            XCTAssertEqual(
                error as? ScreenCaptureRequestGate.StartError,
                .quarantined(operation: "shareable-content")
            )
        }

        XCTAssertEqual(gate.finishOperation(operation), .releasedQuarantine)
        XCTAssertEqual(gate.status, .idle)
        XCTAssertNoThrow(try gate.beginSession())
    }

    func testCompletedOperationCannotBeQuarantinedByStaleTimer() throws {
        let gate = ScreenCaptureRequestGate()
        let session = try gate.beginSession()
        let operation = try XCTUnwrap(
            gate.beginOperation(in: session, name: "display:7")
        )

        XCTAssertEqual(gate.finishOperation(operation), .completed)
        XCTAssertFalse(gate.timeOut(operation))
        XCTAssertEqual(gate.status, .active(operation: nil))

        gate.finishSession(session)
        XCTAssertEqual(gate.status, .idle)
    }

    func testEndingSessionWithPendingSystemRequestKeepsItQuarantined() throws {
        let gate = ScreenCaptureRequestGate()
        let session = try gate.beginSession()
        let operation = try XCTUnwrap(
            gate.beginOperation(in: session, name: "window:99")
        )

        gate.finishSession(session)
        XCTAssertEqual(gate.status, .quarantined(operation: "window:99"))
        XCTAssertEqual(gate.finishOperation(operation), .releasedQuarantine)
        XCTAssertEqual(gate.status, .idle)
    }

    func testBrokerSerializesAllClientsThroughInjectedGate() throws {
        let gate = ScreenCaptureRequestGate()
        let broker = MacScreenCaptureBroker(requestGate: gate, timeout: 0.01)
        let session = try broker.beginSession()

        XCTAssertThrowsError(try broker.beginSession()) { error in
            guard case CaptureError.screenCaptureRequestInFlight = error else {
                return XCTFail("应映射成正在进行中的捕获事务，实际为 \(error)")
            }
        }

        broker.finishSession(session)
        let nextSession = try broker.beginSession()
        broker.finishSession(nextSession)
        XCTAssertEqual(gate.status, .idle)
    }

    func testBrokerPreservesQuarantineFromAnyClient() throws {
        let gate = ScreenCaptureRequestGate()
        let broker = MacScreenCaptureBroker(requestGate: gate, timeout: 0.01)
        let rawSession = try gate.beginSession()
        let operation = try XCTUnwrap(
            gate.beginOperation(in: rawSession, name: "recording:start-stream")
        )
        XCTAssertTrue(gate.timeOut(operation))
        gate.finishSession(rawSession)

        XCTAssertThrowsError(try broker.beginSession()) { error in
            guard case CaptureError.screenCaptureRequestQuarantined(let name) = error else {
                return XCTFail("应保留超时隔离，实际为 \(error)")
            }
            XCTAssertEqual(name, "recording:start-stream")
        }

        XCTAssertEqual(gate.finishOperation(operation), .releasedQuarantine)
        XCTAssertNoThrow(try broker.beginSession())
    }
}
