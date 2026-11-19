import Foundation

/// How the dictation shortcut is used, for the rules below.
public enum PressMode: Sendable, Equatable {
    /// Hold to talk.
    case hold
    /// Press to start, press again to stop.
    case toggle
    /// Hold to talk, or a quick tap to start and another press to stop.
    case holdOrToggle
}

/// A press of the dictation shortcut that came while the last dictation was still being turned into
/// text. It is remembered, and listening starts as soon as that work ends, so the next sentence is not
/// lost to a key that seemed to do nothing.
///
/// A press is remembered; a second press takes it back; letting go of a held key after a
/// real hold takes it back too (there is nothing left to start), and after a quick tap leaves a dictation
/// that will run until the next press.
public struct WaitingPress: Sendable, Equatable {
    /// What listening should start with once the earlier dictation is done.
    public struct Start: Sendable, Equatable {
        /// When the key really went down, so a hold is measured from the press and not from the start.
        public var pressedAt: Date
        /// The dictation runs until the next press: the key is not being held.
        public var handsFree: Bool
        /// Which of the caller's shortcuts was pressed.
        public var tag: Int
    }

    public private(set) var waiting: Start?

    public init() {}

    /// The key went down while Chirp was busy. `tag` says which shortcut; a different one from the press
    /// already remembered is ignored.
    public mutating func keyDown(mode: PressMode, tag: Int = 0, at now: Date = Date()) {
        guard let held = waiting else {
            // Tap-to-start never ends on letting go: it is hands-free from the start.
            waiting = Start(pressedAt: now, handsFree: mode == .toggle, tag: tag)
            return
        }
        guard held.tag == tag else { return }
        // A press on a remembered tap is the press that would have stopped it: the two cancel out.
        // A press while the key is believed down is a key repeat.
        if held.handsFree { waiting = nil }
    }

    /// The key came up while Chirp was still busy.
    public mutating func keyUp(mode: PressMode, tag: Int = 0, tapSeconds: Double, at now: Date = Date()) {
        guard let held = waiting, held.tag == tag, !held.handsFree, mode != .toggle else { return }
        if mode == .holdOrToggle, now.timeIntervalSince(held.pressedAt) < tapSeconds {
            waiting?.handsFree = true
        } else {
            // A whole hold happened while busy: nothing was recorded, and nothing is left to start.
            waiting = nil
        }
    }

    /// The user cancelled: they asked for quiet, not for a recording later.
    public mutating func cancel() { waiting = nil }

    /// The earlier dictation is done. Returns what to start, if a press is waiting, and forgets it.
    public mutating func take() -> Start? {
        defer { waiting = nil }
        return waiting
    }
}
