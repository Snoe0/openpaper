import Foundation

/// The most recent console messages of each artboard (at most `capacity` per board).
public struct ConsoleLog: Sendable {
    public let capacity: Int
    private var entries: [String: [ConsoleEntry]] = [:]

    public init(capacity: Int = 500) {
        self.capacity = capacity
    }

    public mutating func append(_ entry: ConsoleEntry) {
        entries[entry.artboardID, default: []].append(entry)
        let overflow = entries[entry.artboardID, default: []].count - capacity
        if overflow > 0 { entries[entry.artboardID]?.removeFirst(overflow) }
    }

    /// Forgets a deleted board's messages.
    public mutating func remove(artboardID: String) {
        entries[artboardID] = nil
    }

    /// One board's messages, or every board's, oldest first.
    public func entries(artboardID: String?) -> [ConsoleEntry] {
        guard let artboardID else { return entries.values.joined().sorted { $0.timestamp < $1.timestamp } }
        return entries[artboardID] ?? []
    }
}
