/// What the canvas must do to its web views after the live set changed.
/// Apply in order: snapshot and pause `pause`, release `evict`, resume `resume`, load `load`.
public struct PoolChanges: Equatable, Sendable {
    public var pause: [String]
    public var resume: [String]
    public var load: [String]
    public var evict: [String]

    public init(pause: [String] = [], resume: [String] = [], load: [String] = [], evict: [String] = []) {
        self.pause = pause
        self.resume = resume
        self.load = load
        self.evict = evict
    }

    public var isEmpty: Bool { pause.isEmpty && resume.isEmpty && load.isEmpty && evict.isEmpty }
}

/// The boards that own a web view: live ones, plus paused ones kept for a quick resume.
/// Paused boards are kept least-recently-visible first and evicted in that order once the pool
/// exceeds `capacity`; live boards are never evicted.
public struct LivePool: Sendable {
    public let capacity: Int
    public private(set) var live: [String] = []
    /// Oldest first.
    public private(set) var paused: [String] = []

    public init(capacity: Int) {
        self.capacity = capacity
    }

    @discardableResult
    public mutating func update(live desired: [String]) -> PoolChanges {
        let wanted = Set(desired)
        var changes = PoolChanges(pause: live.filter { !wanted.contains($0) })
        paused += changes.pause
        for id in desired where !live.contains(id) {
            if let index = paused.firstIndex(of: id) {
                paused.remove(at: index)
                changes.resume.append(id)
            } else {
                changes.load.append(id)
            }
        }
        live = desired
        changes.evict = evictOverflow()
        return changes
    }

    /// Forgets a board, e.g. one that was deleted; its web view must be released by the caller.
    public mutating func remove(_ id: String) {
        live.removeAll { $0 == id }
        paused.removeAll { $0 == id }
    }

    private mutating func evictOverflow() -> [String] {
        let overflow = min(max(live.count + paused.count - capacity, 0), paused.count)
        let evicted = Array(paused.prefix(overflow))
        paused.removeFirst(overflow)
        return evicted
    }
}
