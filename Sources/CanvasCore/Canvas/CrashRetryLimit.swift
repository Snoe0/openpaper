import Foundation

/// Decides whether a board whose page crashed gets reloaded: at most `maxRetries` times within
/// `window` seconds, after which it stays a snapshot until reset (e.g. by an edit).
public struct CrashRetryLimit: Sendable {
    public let maxRetries: Int
    public let window: TimeInterval
    private var crashes: [String: [TimeInterval]] = [:]

    public init(maxRetries: Int = 2, window: TimeInterval = 10) {
        self.maxRetries = maxRetries
        self.window = window
    }

    /// Records a crash at `time` (seconds) and says whether to reload.
    public mutating func shouldRetry(_ id: String, at time: TimeInterval) -> Bool {
        var recent = crashes[id, default: []].filter { time - $0 <= window }
        recent.append(time)
        crashes[id] = recent
        return recent.count <= maxRetries
    }

    public mutating func reset(_ id: String) {
        crashes[id] = nil
    }
}
