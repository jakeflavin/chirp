import Foundation

/// Keeps a helper process that dies again and again from being started over and over. After `limit`
/// deaths in a row with no request finished between them, no start is allowed for `rest` seconds.
public struct RestartLimit: Sendable {
    public var limit: Int
    public var rest: TimeInterval
    /// Deaths in a row since the last request that finished.
    public private(set) var deaths = 0
    /// No start before this time.
    public private(set) var restingUntil: Date?

    public init(limit: Int = 3, rest: TimeInterval = 60) {
        self.limit = limit
        self.rest = rest
    }

    /// The helper went away in the middle of a request.
    public mutating func died(at now: Date) {
        deaths += 1
        if deaths >= limit {
            restingUntil = now.addingTimeInterval(rest)
            deaths = 0
        }
    }

    /// A request finished: the helper is working.
    public mutating func succeeded() {
        deaths = 0
        restingUntil = nil
    }

    /// Whether a new helper may be started now.
    public func mayStart(at now: Date) -> Bool {
        guard let restingUntil else { return true }
        return now >= restingUntil
    }
}
