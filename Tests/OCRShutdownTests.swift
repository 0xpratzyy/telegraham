import XCTest
@testable import Pidgy

final class OCRShutdownTests: XCTestCase {
    func testTerminationCannotBeRearmedByLateLifecycleCallbacks() {
        let tracker = OCRWorkTracker()
        tracker.stop(permanently: true)
        tracker.resume()
        XCTAssertTrue(tracker.isStopped)
        XCTAssertNil(tracker.begin {})
    }

    func testStopCancelsNativeWorkAndRejectsNewRequests() async throws {
        let tracker = OCRWorkTracker()
        let canceled = expectation(description: "Native request canceled")
        let id = try XCTUnwrap(tracker.begin {
            XCTAssertTrue(tracker.isStopped) // Callback must run outside the lock.
            canceled.fulfill()
        })
        tracker.stop()
        await fulfillment(of: [canceled], timeout: 1)
        XCTAssertNil(tracker.begin {})
        XCTAssertTrue(tracker.hasActiveWork)
        tracker.finish(id)
        let idle = await tracker.waitUntilIdle(timeout: 1)
        XCTAssertTrue(idle)
        tracker.resume()
        XCTAssertNotNil(tracker.begin {})
    }

    func testUncooperativeNativeWorkHasBoundedDrain() async throws {
        let tracker = OCRWorkTracker()
        let id = try XCTUnwrap(tracker.begin {})
        tracker.stop()
        let start = ContinuousClock.now
        let idle = await tracker.waitUntilIdle(timeout: 0.05)
        XCTAssertFalse(idle)
        XCTAssertLessThan(start.duration(to: .now), .seconds(1))
        tracker.finish(id)
    }

    func testDrainWaitsForActualNativeCompletion() async throws {
        let tracker = OCRWorkTracker()
        let id = try XCTUnwrap(tracker.begin {})
        tracker.stop()
        let finish = Task {
            try await Task.sleep(for: .milliseconds(40))
            tracker.finish(id)
        }
        let idle = await tracker.waitUntilIdle(timeout: 1)
        XCTAssertTrue(idle)
        try await finish.value
    }
}
