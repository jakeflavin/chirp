import Foundation

/// Lets one piece of work at a time through, in the order it asked. The language model uses it so that two
/// runs never have the model at once.
public final class TurnGate: @unchecked Sendable {
    private let lock = NSLock()
    /// True while someone has the turn.
    private var taken = false
    /// Callers waiting for the turn, first come first served.
    private var waiting: [CheckedContinuation<Void, Never>] = []

    public init() {}

    /// Waits for the turn and takes it. Every `enter()` must be followed by one `leave()`. A caller whose
    /// task is cancelled still waits for its turn: it checks for cancellation once it has it.
    public func enter() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if taken {
                waiting.append(continuation)
                lock.unlock()
            } else {
                taken = true
                lock.unlock()
                continuation.resume()
            }
        }
    }

    /// Gives the turn to the caller that has waited longest, or leaves the gate free.
    public func leave() {
        lock.lock()
        let next = waiting.isEmpty ? nil : waiting.removeFirst()
        if next == nil { taken = false }
        lock.unlock()
        next?.resume()
    }

    /// How many callers are waiting behind the one that has the turn.
    public var queued: Int {
        lock.lock()
        defer { lock.unlock() }
        return waiting.count
    }
}
