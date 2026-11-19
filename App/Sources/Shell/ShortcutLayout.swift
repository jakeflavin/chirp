import AppKit
import ChirpCore
import KeyboardShortcuts
import SwiftUI

extension KeyboardShortcuts.Name {
    /// Starts a voice note, or stops the recording under way.
    static let recordNote = Self("recordNote", default: .init(.n, modifiers: [.option]))
}

/// The shortcut layout: everything under the right hand, so one hand reaches every action.
/// Holding Right Option alone dictates; with it held, N is a voice note, M a meeting, L reads aloud,
/// U summarizes, I fixes writing, K rephrases, O opens the Library and P types the last dictation again.
/// ⌥Space is hands-free dictation.
///
/// A shortcut that is Option and one key answers **only while the right Option key is down**, so Left
/// Option keeps typing its symbols (⌥N is ˜, ⌥O is ø). macOS's shortcut registration cannot tell the
/// two Option keys apart, so these are registered when the right one goes down and unregistered when it
/// comes up. The right Option key is watched the way the dictation hold key is (`HoldKeyMonitor`), and
/// the shortcut is switched on and off the way "Fix the sentence" is (`SentenceFixer`). A shortcut the
/// user changes to anything with another modifier answers all the time, as before.
@MainActor
enum ShortcutLayout {
    /// The shortcuts that are right Option and a letter by default, in the order of the layout.
    static let rightOption: [KeyboardShortcuts.Name] = [
        .recordNote, .recordMeeting, .readSelection, .summarize, .writePanel, .rephrase, .openLibrary, .pasteLast,
    ]

    /// Whether a shortcut answers only with the right Option key: it is one of the layout's, and it is
    /// set to Option and one key with nothing else.
    static func needsRightOption(_ name: KeyboardShortcuts.Name) -> Bool {
        guard rightOption.contains(name), let shortcut = KeyboardShortcuts.getShortcut(for: name) else { return false }
        return shortcut.modifiers.intersection([.command, .option, .control, .shift]) == .option
    }

    /// A shortcut's keys as shown to the user: "right ⌥ N" where there is room, "⌥N" on a perch tile or a
    /// popover row. Nil when it has none.
    static func label(_ name: KeyboardShortcuts.Name, short: Bool = false) -> String? {
        guard let shortcut = KeyboardShortcuts.getShortcut(for: name) else { return nil }
        let keys = shortcut.description
        return ShortcutKeys.label(keys: keys, rightOption: needsRightOption(name), short: short)
    }

    /// How dictation is started, for the Dictate tile: "hold ⌥" with a hold key, else the shortcut.
    static func dictateLabel(holdKey: HoldKey) -> String? {
        ShortcutKeys.holdLabel(holdKey.rawValue) ?? label(.dictate, short: true)
    }

    // MARK: Moving to the layout

    /// The defaults before this layout. An install still on one of them moves to the new key; a
    /// shortcut the user chose is left alone.
    private static let before: [(KeyboardShortcuts.Name, KeyboardShortcuts.Shortcut)] = [
        (.recordMeeting, .init(.m, modifiers: [.control, .option])),
        (.readSelection, .init(.r, modifiers: [.control, .option])),
        (.summarize, .init(.s, modifiers: [.control, .option])),
        (.writePanel, .init(.space, modifiers: [.control, .option])),
        (.openLibrary, .init(.l, modifiers: [.option, .command])),
        (.pasteLast, .init(.v, modifiers: [.control, .option])),
        // "Fix the sentence" stayed on ⌃⌥F until the sentence bird was built; it is ⌥⇥ now.
        (.fixSentence, .init(.f, modifiers: [.control, .option])),
    ]

    /// Once per install: shortcuts still on their old default take the layout's key, and the shortcuts
    /// that no longer exist are forgotten.
    static func adopt() {
        let key = "shortcutLayout"
        // 3: "Fix the sentence" moved from ⌃⌥F to ⌥⇥.
        guard UserDefaults.standard.integer(forKey: key) < 3 else { return }
        UserDefaults.standard.set(3, forKey: key)
        var moved: [String] = []
        for (name, old) in before where KeyboardShortcuts.getShortcut(for: name) == old {
            KeyboardShortcuts.reset(name)
            moved.append(name.rawValue)
        }
        for gone in ["dictateWithCleanup", "voiceEdit", "reviewFixes"] {
            UserDefaults.standard.removeObject(forKey: "KeyboardShortcuts_\(gone)")
        }
        if !moved.isEmpty { Log.write("shortcuts", "moved to the right Option layout: \(moved.joined(separator: ", "))") }
    }

    // MARK: Answering only with the right Option key

    private static let watcher = HoldKeyMonitor()
    /// When the right Option shortcuts answer (`ShortcutWindow`: from the key going down until it and
    /// any letter pressed with it have come up).
    private static var window = ShortcutWindow()
    /// Closes the shortcuts again a moment into a hold that is a dictation, or when a letter never comes up.
    private static var closer: Task<Void, Never>?
    /// True while the right Option shortcuts are registered with macOS.
    private(set) static var open = false
    /// Whether holding Right Option alone starts a dictation now. Set by the dictation controller.
    static var holdDictates: () -> Bool = { false }
    /// Drops the dictation the hold began. Set by the dictation controller.
    static var holdWasShortcut: () -> Void = {}

    /// Called once at launch before any shortcut has its handler, so this runs first when one is pressed:
    /// the hold that led to the shortcut was not a dictation, and what it began is dropped before the
    /// shortcut's own work starts.
    static func prepare() {
        adopt()
        for name in rightOption {
            KeyboardShortcuts.onKeyDown(for: name) {
                window.letterDown(name.rawValue)
                if needsRightOption(name) { holdWasShortcut() }
            }
            KeyboardShortcuts.onKeyUp(for: name) {
                window.letterUp(name.rawValue)
                // After the shortcut's own handler for this release has run.
                Task { @MainActor in follow() }
            }
        }
    }

    /// Starts watching the right Option key. Called once at launch, after every shortcut has its handler.
    static func start() {
        watcher.followsDictate = false
        watcher.onHeld = { opened() }
        watcher.onReleased = { released() }
        watcher.key = .rightOption
        apply()
        // TESTING: `chirp://debug/right-option?down=1` / `up=1` stand in for the key, and `letter=recordNote&down=1`
        // (`up=1`) for a shortcut's letter; `state` has `shortcuts`.
        LinkHandler.commands["right-option"] = { q in
            if let letter = q["letter"] {
                if q["down"] == "1" { window.letterDown(letter) }
                if q["up"] == "1" { window.letterUp(letter) }
                return follow()
            }
            if q["down"] == "1" { opened() }
            if q["up"] == "1" { released() }
        }
        LinkHandler.stateProviders["shortcuts"] = {
            var keys: [String: String] = [:]
            for name in rightOption + [.dictate, .fixSentence] { keys[name.rawValue] = label(name) ?? "" }
            return ["open": open, "keys": keys, "rightOptionOnly": rightOption.filter(needsRightOption).map(\.rawValue),
                    "tiles": Dictionary(uniqueKeysWithValues: rightOption.map { ($0.rawValue, label($0, short: true) ?? "") })] as [String: Any]
        }
    }

    /// Registers each shortcut that should answer now and unregisters the rest: one whose feature is off
    /// never answers, a right Option one only while that key is down. Called when the features change,
    /// when a shortcut is changed in Settings, and as the key goes down and up.
    static func apply() {
        let on = Features.shared.set
        for (feature, names) in Features.shortcuts {
            for name in names where name != .fixSentence {
                answer(name, on.isOn(feature))
            }
        }
        answer(.openLibrary, true)
    }

    private static func answer(_ name: KeyboardShortcuts.Name, _ featureOn: Bool) {
        if featureOn, !needsRightOption(name) || open {
            KeyboardShortcuts.enable(name)
        } else {
            KeyboardShortcuts.disable(name)
        }
    }

    /// Registers or unregisters the shortcuts when the window has opened or closed.
    private static func follow() {
        guard window.isOpen != open else { return }
        open = window.isOpen
        apply()
    }

    private static func opened() {
        window.optionDown()
        follow()
        closer?.cancel()
        // A hold that starts a dictation is taken for a shortcut only at its start: later, a letter is a
        // slip while talking, and what was said is kept (the hold key's own rule).
        guard holdDictates() else { return }
        closer = Task {
            try? await Task.sleep(for: .seconds(ShortcutKeys.shortcutWindow))
            guard !Task.isCancelled, !ShortcutKeys.answers(heldFor: ShortcutKeys.shortcutWindow, holdDictates: holdDictates()) else { return }
            released()
        }
    }

    /// The key came up (or the start of a dictating hold has passed). A letter still down keeps its
    /// shortcut until it comes up, for three seconds at most.
    private static func released() {
        closer?.cancel()
        window.optionUp()
        follow()
        guard open else { return }
        closer = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            window.giveUp()
            follow()
        }
    }
}

/// A row in Settings › Shortcuts: the name, "right" before the keys when the shortcut answers only with
/// the right Option key, and the field that records a new one.
struct ShortcutRow: View {
    let title: String
    var help: String?
    let name: KeyboardShortcuts.Name
    /// Redrawn when the shortcut is changed.
    @State private var version = 0

    var body: some View {
        LabeledContent {
            HStack(spacing: 6) {
                let _ = version
                if ShortcutLayout.needsRightOption(name) {
                    Text("right").font(.system(size: 12)).foregroundStyle(Color.quiet).accessibilityHidden(true)
                }
                KeyboardShortcuts.Recorder(for: name) { _ in
                    version += 1
                    ShortcutLayout.apply()
                }
                .accessibilityLabel(title)
                .accessibilityValue(ShortcutLayout.label(name) ?? "Not set")
            }
        } label: {
            Text(title)
            if let help { Text(help) }
        }
    }
}
