import Foundation

/// Keeps Chirp from waiting, again and again, on an app that has stopped answering.
///
/// Every question Chirp asks another app about its text holds Chirp up until the app answers or a time
/// limit passes. An app that has hung answers nothing, so each look would cost the full limit, several
/// times over, and Chirp's own bar would freeze with it. Slower than 0.8 seconds counts as slow, and a
/// hung app is left alone for 30 seconds.
///
/// On a busy Mac the first read of an app often takes 1.2–1.5 s, and resting it for 30 s
/// after that one answer would leave the user without underlines for half a minute. So a slow answer
/// that came back is used, and the app is only left alone after `strikes` slow answers in a row: for `firstRest`
/// (5 s) the first time, and `rest` (30 s) if it is still slow after that. An answer slower than `hang`
/// (3 s) is an app that has truly stopped: it is left alone for `rest` at once. A quick answer clears it all.
public struct SlowAppGuard: Sendable {
    /// An answer slower than this counts as slow.
    public var slow: TimeInterval
    /// An answer slower than this means the app has stopped answering: it rests at once, for `rest`.
    public var hang: TimeInterval
    /// How many slow answers in a row before the app is left alone.
    public var strikes: Int
    /// The first rest after slow answers in a row.
    public var firstRest: TimeInterval
    /// How long a hung app, or one still slow after its first rest, is left alone.
    public var rest: TimeInterval

    private struct App: Sendable {
        var slowInARow = 0
        var rests = 0
        var until: Date?
    }
    /// What is known of each app, by process id.
    private var apps: [Int32: App] = [:]

    public init(slow: TimeInterval = 0.8, hang: TimeInterval = 3, strikes: Int = 3, firstRest: TimeInterval = 5, rest: TimeInterval = 30) {
        self.slow = slow
        self.hang = hang
        self.strikes = strikes
        self.firstRest = firstRest
        self.rest = rest
    }

    /// Whether this app is being left alone for now.
    public func resting(_ pid: Int32, now: Date = Date()) -> Bool {
        apps[pid]?.until.map { now < $0 } ?? false
    }

    /// Notes how long the app took to answer. Returns how long it is now left alone, or nil when it is not
    /// (a quick answer, or a slow one that has not happened `strikes` times in a row: its answer is used).
    @discardableResult
    public mutating func record(_ pid: Int32, took seconds: TimeInterval, now: Date = Date()) -> TimeInterval? {
        var app = apps[pid] ?? App()
        defer {
            apps[pid] = app
            // Process ids are reused over days; apps long since allowed back are dropped.
            if apps.count > 64 { apps = apps.filter { $0.value.until.map { $0 > now } ?? false } }
        }
        guard seconds >= slow else {
            app = App()
            return nil
        }
        let length: TimeInterval
        if seconds >= hang {
            length = rest
        } else {
            app.slowInARow += 1
            guard app.slowInARow >= strikes else { return nil }
            length = app.rests == 0 ? firstRest : rest
        }
        app.slowInARow = 0
        app.rests += 1
        app.until = now.addingTimeInterval(length)
        return length
    }
}
