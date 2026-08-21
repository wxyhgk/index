import XCTest
@testable import IndexApp

@MainActor
final class PinPassthroughRegistryTests: XCTestCase {
    private final class FakePin: PinPassthroughControlling {
        var changes: [Bool] = []
        func setPinPassthrough(_ enabled: Bool) { changes.append(enabled) }
    }

    func testLiftAllRestoresEveryRegisteredPin() {
        let registry = PinPassthroughRegistry()
        let imagePin = FakePin()
        let moleculePin = FakePin()
        registry.register(imagePin)
        registry.register(moleculePin)

        XCTAssertTrue(registry.hasPassthroughPins)
        registry.liftAll()

        XCTAssertEqual(imagePin.changes, [false])
        XCTAssertEqual(moleculePin.changes, [false])
    }

    func testUnregisteredAndReleasedPinsDoNotKeepMenuVisible() {
        let registry = PinPassthroughRegistry()
        var pin: FakePin? = FakePin()
        registry.register(pin!)
        registry.unregister(pin!)
        XCTAssertFalse(registry.hasPassthroughPins)

        pin = FakePin()
        registry.register(pin!)
        pin = nil
        XCTAssertFalse(registry.hasPassthroughPins)
    }
}
