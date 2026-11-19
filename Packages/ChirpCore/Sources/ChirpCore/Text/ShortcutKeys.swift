import Foundation

/// How Chirp's shortcuts are written for the user, and the one timing rule of the right Option layout.
public enum ShortcutKeys {
    /// A letter pressed within this long of the hold key going down makes the hold the start of a
    /// shortcut (right ⌥ N): the dictation it began is dropped. Later, a letter is a slip while talking
    /// and what was said is kept.
    public static let shortcutWindow: Double = 1

    /// Whether a letter pressed this long into a hold counts as a shortcut. With a hold key that does
    /// not dictate, the shortcuts answer for as long as the key is down.
    public static func answers(heldFor seconds: Double, holdDictates: Bool) -> Bool {
        !holdDictates || seconds < shortcutWindow
    }

    /// A shortcut's keys as shown. One that answers only with the right Option key is "right ⌥ N" where
    /// there is room and "⌥N" on a tile; any other is shown as macOS writes it.
    public static func label(keys: String, rightOption: Bool, short: Bool) -> String {
        guard rightOption, !short, keys.hasPrefix("⌥") else { return keys }
        return "right ⌥ " + keys.dropFirst()
    }

    /// The words under the Dictate action: how dictation is started with this hold key.
    public static func holdLabel(_ key: String) -> String? {
        switch key {
        case "rightOption": "hold ⌥"
        case "rightCommand": "hold ⌘"
        case "fn": "hold fn"
        default: nil
        }
    }
}

/// When the shortcuts that are right Option and a letter answer: from that key going down until it
/// comes up. A shortcut whose letter is still down as the Option key comes up (people let go of the
/// modifier first as often as not) stays until its letter comes up too, because most of them act as
/// the letter is released.
public struct ShortcutWindow: Sendable, Equatable {
    /// True while the shortcuts are registered with macOS.
    public private(set) var isOpen = false
    /// The shortcuts whose letter is down now.
    private var down: Set<String> = []
    /// The Option key has come up and the window closes with the last letter.
    private var closing = false

    public init() {}

    /// The right Option key went down on its own.
    public mutating func optionDown() {
        isOpen = true
        closing = false
    }

    /// The right Option key came up, or the start of a hold that dictates has passed.
    public mutating func optionUp() {
        if down.isEmpty { isOpen = false } else { closing = true }
    }

    /// A shortcut's letter went down, or came up.
    public mutating func letterDown(_ name: String) { down.insert(name) }

    public mutating func letterUp(_ name: String) {
        down.remove(name)
        if closing, down.isEmpty {
            isOpen = false
            closing = false
        }
    }

    /// A letter's release never arrived (the shortcut was changed while it was down, say): close anyway.
    public mutating func giveUp() {
        down = []
        if closing {
            isOpen = false
            closing = false
        }
    }
}

