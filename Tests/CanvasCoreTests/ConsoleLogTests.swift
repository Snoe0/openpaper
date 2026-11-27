import XCTest
@testable import CanvasCore

final class ConsoleLogTests: XCTestCase {
    func testKeepsTheNewestEntriesPerBoard() {
        var log = ConsoleLog(capacity: 2)
        for index in 0..<3 { log.append(entry("a", "m\(index)", at: Double(index))) }
        log.append(entry("b", "only", at: 10))

        XCTAssertEqual(log.entries(artboardID: "a").map(\.message), ["m1", "m2"])
        XCTAssertEqual(log.entries(artboardID: "b").map(\.message), ["only"])
    }

    func testAllEntriesAreMergedOldestFirst() {
        var log = ConsoleLog()
        log.append(entry("a", "second", at: 2))
        log.append(entry("b", "first", at: 1))
        log.append(entry("a", "third", at: 3))

        XCTAssertEqual(log.entries(artboardID: nil).map(\.message), ["first", "second", "third"])
    }

    func testRemovingABoardDropsItsEntries() {
        var log = ConsoleLog()
        log.append(entry("a", "x", at: 1))
        log.append(entry("b", "y", at: 2))

        log.remove(artboardID: "a")

        XCTAssertEqual(log.entries(artboardID: nil).map(\.message), ["y"])
    }

    func testTheDefaultCapacityIs500() {
        XCTAssertEqual(ConsoleLog().capacity, 500)
    }

    private func entry(_ id: String, _ message: String, at seconds: Double) -> ConsoleEntry {
        ConsoleEntry(artboardID: id, level: "log", message: message, timestamp: Date(timeIntervalSince1970: seconds))
    }
}
