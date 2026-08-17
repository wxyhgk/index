import XCTest
@testable import MacShot

@MainActor
final class GallerySessionLifecycleTests: XCTestCase {

    func testEndingSessionCancelsUnstructuredTasksAndRejectsNewWork() async throws {
        let lifecycle = GallerySessionLifecycle()
        lifecycle.begin()
        var firstStarted = false
        var firstCancelled = false
        var lateStarted = false

        lifecycle.runIfAbsent(.nextPage) {
            firstStarted = true
            do {
                try await Task.sleep(for: .seconds(10))
            } catch {
                firstCancelled = Task.isCancelled
            }
        }
        await Task.yield()
        XCTAssertTrue(firstStarted)
        XCTAssertEqual(lifecycle.activeTaskCount, 1)

        lifecycle.end()
        lifecycle.runReplacing(.gridSnapshot) { lateStarted = true }
        try await Task.sleep(for: .milliseconds(10))

        XCTAssertTrue(firstCancelled)
        XCTAssertFalse(lateStarted)
        XCTAssertEqual(lifecycle.activeTaskCount, 0)
    }

    func testReplacingTaskCannotLetOldCompletionRemoveNewEntry() async throws {
        let lifecycle = GallerySessionLifecycle()
        lifecycle.begin()
        var latestFinished = false

        lifecycle.runReplacing(.gridSnapshot) {
            try? await Task.sleep(for: .seconds(10))
        }
        lifecycle.runReplacing(.gridSnapshot) {
            try? await Task.sleep(for: .milliseconds(20))
            latestFinished = true
        }
        await Task.yield()

        XCTAssertEqual(lifecycle.activeTaskCount, 1)
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertTrue(latestFinished)
        XCTAssertEqual(lifecycle.activeTaskCount, 0)
    }

    func testCloseExitsViewBeforeThumbnailReleaseAndStaleCloseCannotHitReopenedSession() async {
        let lifecycle = GallerySessionLifecycle()
        lifecycle.begin()
        var events: [String] = []

        let closeTask = lifecycle.closeAfterExitingView(
            exitView: { events.append("exit") },
            releaseThumbnails: { events.append("release") }
        )

        XCTAssertEqual(events, ["exit"])
        XCTAssertFalse(lifecycle.isActive)
        await closeTask.value
        XCTAssertEqual(events, ["exit", "release"])

        lifecycle.begin()
        let staleClose = lifecycle.closeAfterExitingView(
            exitView: { events.append("second-exit") },
            releaseThumbnails: { events.append("stale-release") }
        )
        lifecycle.begin()
        await staleClose.value

        XCTAssertTrue(lifecycle.isActive)
        XCTAssertFalse(events.contains("stale-release"))
    }

    func testBeginIsIdempotentWhileWindowRemainsOpen() {
        let lifecycle = GallerySessionLifecycle()
        let first = lifecycle.begin()
        let repeated = lifecycle.begin()

        XCTAssertEqual(first, repeated)
        XCTAssertTrue(lifecycle.isActive)
    }
}
