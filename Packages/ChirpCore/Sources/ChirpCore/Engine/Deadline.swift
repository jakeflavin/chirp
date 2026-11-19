import Foundation

/// A wait with a limit. Chirp waits on other processes and other apps (a model's helper, the speech
/// worker, Core Audio, another app's window), and any of those can fail to come back. A recording's
/// finishing steps could wait on one for ever, so each such wait goes through here.
public enum Deadline {
    /// The work did not end within its limit.
    public struct Passed: Error, Equatable, Sendable {
        public var seconds: Double
        public init(seconds: Double) { self.seconds = seconds }
    }

    /// Runs `work` and returns what it gives, or nil when it has not ended within `seconds`. The work is
    /// then cancelled and left behind: work that ignores being cancelled cannot hold the caller.
    public static func run<T: Sendable>(seconds: Double, _ work: @escaping @Sendable () async -> T) async -> T? {
        try? await attempt(seconds: seconds) { await work() }
    }

    /// `run` for work that can fail: its own error comes through, and `Passed` is thrown at the limit.
    public static func attempt<T: Sendable>(seconds: Double, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        let race = Race<T>()
        let worker = Task {
            do { race.finish(.success(try await work())) } catch { race.finish(.failure(error)) }
        }
        let timer = Task {
            try? await Task.sleep(for: .seconds(max(0, seconds)))
            guard !Task.isCancelled else { return }
            if race.finish(.failure(Passed(seconds: seconds))) { worker.cancel() }
        }
        defer { timer.cancel() }
        return try await withTaskCancellationHandler {
            try await race.value()
        } onCancel: {
            // The caller gave up: so does the work, and the caller is let go at once.
            worker.cancel()
            race.finish(.failure(CancellationError()))
        }
    }

    /// Whichever result arrives first, handed to whoever is waiting. Later ones are dropped.
    private final class Race<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Result<T, Error>?
        private var waiter: CheckedContinuation<T, Error>?

        /// True when this result was the first.
        @discardableResult
        func finish(_ value: Result<T, Error>) -> Bool {
            let (first, resume): (Bool, CheckedContinuation<T, Error>?) = lock.withLock {
                guard result == nil else { return (false, nil) }
                result = value
                defer { waiter = nil }
                return (true, waiter)
            }
            resume?.resume(with: value)
            return first
        }

        func value() async throws -> T {
            try await withCheckedThrowingContinuation { continuation in
                let ready: Result<T, Error>? = lock.withLock {
                    if let result { return result }
                    waiter = continuation
                    return nil
                }
                if let ready { continuation.resume(with: ready) }
            }
        }
    }
}
