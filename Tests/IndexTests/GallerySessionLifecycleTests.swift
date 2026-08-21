import XCTest
@testable import IndexApp

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
        // 等被取消的任务真正观察到取消。不用固定 10ms：负载高的 CI 机器上
        // MainActor 调度就可能超过它。
        let deadline = Date().addingTimeInterval(2)
        while !firstCancelled && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }

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
        // 等最新任务完成。不用固定 40ms：20ms sleep + MainActor 调度在负载高的
        // CI 机器上会超预算（2026-08-17 三个 CI 运行全挂在这）。
        let deadline = Date().addingTimeInterval(2)
        while !latestFinished && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
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
