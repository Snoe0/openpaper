import XCTest
@testable import CanvasCore

final class LivePoolTests: XCTestCase {
    func testNewLiveBoardsAreLoaded() {
        var pool = LivePool(capacity: 3)

        XCTAssertEqual(pool.update(live: ["a", "b"]), PoolChanges(load: ["a", "b"]))
        XCTAssertEqual(pool.live, ["a", "b"])
    }

    func testBoardsThatStopBeingLiveArePausedAndKept() {
        var pool = LivePool(capacity: 3)
        pool.update(live: ["a", "b"])

        XCTAssertEqual(pool.update(live: ["b"]), PoolChanges(pause: ["a"]))
        XCTAssertEqual(pool.live, ["b"])
        XCTAssertEqual(pool.paused, ["a"])
    }

    func testPausedBoardsAreResumedRatherThanReloaded() {
        var pool = LivePool(capacity: 3)
        pool.update(live: ["a"])
        pool.update(live: [])

        XCTAssertEqual(pool.update(live: ["a"]), PoolChanges(resume: ["a"]))
        XCTAssertEqual(pool.paused, [])
    }

    func testTheLeastRecentlyVisiblePausedBoardIsEvictedWhenThePoolIsFull() {
        var pool = LivePool(capacity: 3)
        pool.update(live: ["a"])
        pool.update(live: ["b"]) // a paused at tick 2
        pool.update(live: ["c"]) // b paused at tick 3
        pool.update(live: ["d"]) // c paused at tick 4; pool a, b, c, d is over capacity → a evicted

        XCTAssertEqual(pool.paused, ["b", "c"])
        XCTAssertEqual(pool.update(live: ["e"]), PoolChanges(pause: ["d"], load: ["e"], evict: ["b"]))
        XCTAssertEqual(pool.paused, ["c", "d"])
    }

    func testEvictedBoardsAreLoadedFreshWhenTheyComeBack() {
        var pool = LivePool(capacity: 1)
        pool.update(live: ["a"])
        pool.update(live: ["b"])

        XCTAssertEqual(pool.update(live: ["a"]), PoolChanges(pause: ["b"], load: ["a"], evict: ["b"]))
    }

    func testLiveBoardsAreNeverEvicted() {
        var pool = LivePool(capacity: 2)

        let changes = pool.update(live: ["a", "b", "c"])

        XCTAssertEqual(changes, PoolChanges(load: ["a", "b", "c"]))
        XCTAssertEqual(pool.live, ["a", "b", "c"])
    }

    func testRemovingABoardDropsItFromThePool() {
        var pool = LivePool(capacity: 3)
        pool.update(live: ["a", "b"])
        pool.update(live: ["b"])

        pool.remove("a")
        pool.remove("b")

        XCTAssertEqual(pool.live, [])
        XCTAssertEqual(pool.paused, [])
        XCTAssertEqual(pool.update(live: ["a"]), PoolChanges(load: ["a"]))
    }

    func testUnchangedLiveSetChangesNothing() {
        var pool = LivePool(capacity: 3)
        pool.update(live: ["a", "b"])

        XCTAssertEqual(pool.update(live: ["b", "a"]), PoolChanges())
        XCTAssertTrue(PoolChanges().isEmpty)
    }
}
