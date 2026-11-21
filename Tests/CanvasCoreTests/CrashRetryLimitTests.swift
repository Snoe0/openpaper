import XCTest
@testable import CanvasCore

final class CrashRetryLimitTests: XCTestCase {
    func testACrashedBoardIsRetriedTwiceWithinTheWindowThenGivenUp() {
        var limit = CrashRetryLimit(maxRetries: 2, window: 10)

        XCTAssertTrue(limit.shouldRetry("a", at: 0))
        XCTAssertTrue(limit.shouldRetry("a", at: 1))
        XCTAssertFalse(limit.shouldRetry("a", at: 2))
        XCTAssertTrue(limit.shouldRetry("b", at: 2))
    }

    func testCrashesOutsideTheWindowAreForgotten() {
        var limit = CrashRetryLimit(maxRetries: 2, window: 10)
        _ = limit.shouldRetry("a", at: 0)
        _ = limit.shouldRetry("a", at: 1)

        XCTAssertTrue(limit.shouldRetry("a", at: 11.5))
    }

    func testResettingForgetsTheBoardsCrashes() {
        var limit = CrashRetryLimit(maxRetries: 1, window: 10)
        _ = limit.shouldRetry("a", at: 0)

        limit.reset("a")

        XCTAssertTrue(limit.shouldRetry("a", at: 1))
    }

    func testDefaultsMatchTheSpec() {
        let limit = CrashRetryLimit()
        XCTAssertEqual(limit.maxRetries, 2)
        XCTAssertEqual(limit.window, 10)
    }
}
