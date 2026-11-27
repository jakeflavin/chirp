import AppKit
import ChirpCore
import KeyboardShortcuts
import SwiftUI

extension KeyboardShortcuts.Name {
    /// Applies every fix in the sentence the cursor is in: ⌥⇥, the way a developer would expect
    /// autocomplete to work. It is registered only while a sentence has a fix, so at any
    /// other time the keys go to the app in front as usual (tables in Pages and Notes, Safari's fields).
    static let fixSentence = Self("fixSentence", initial: .init(.tab, modifiers: [.option]))
}

/// Offers to fix the sentence the cursor is in: pressing the shortcut applies every spelling and grammar
/// fix for that sentence at once, and puts in a snippet whose cue was typed in it.
/// The shortcut is only claimed while there is something to fix, so it stays free for other apps otherwise.
@MainActor
final class SentenceFixer {
    static let shared = SentenceFixer()

    /// Who made the current offer: "editor" for Chirp's own editor, "other" for a field in another app.
    private var owner = ""
    /// Identifies the current offer, so offering the same fix again does nothing.
    private var key = ""
    /// Puts the offered fix in. Nil when nothing is on offer.
    private var apply: (() -> Void)?
    /// How many fixes the offer applies.
    private(set) var count = 0
    /// True while the shortcut is registered with macOS, which is only while a fix is on offer.
    private(set) var claimed = false

    private init() {
        KeyboardShortcuts.onKeyDown(for: .fixSentence) { [weak self] in self?.trigger() }
        KeyboardShortcuts.disable(.fixSentence)
        LinkHandler.commands["fix-sentence"] = { [weak self] _ in self?.trigger() }
        LinkHandler.stateProviders["sentenceFix"] = { [weak self] in
            ["available": self?.apply != nil, "count": self?.count ?? 0, "owner": self?.owner ?? "",
             "keys": KeyboardShortcuts.getShortcut(for: .fixSentence)?.description ?? "",
             // Whether the keys are claimed from other apps right now (never in a copy started with --no-global-shortcuts).
             "claimed": self?.claimed ?? false] as [String: Any]
        }
    }

    /// Puts a fix on offer and claims the shortcut for it. Nothing is drawn: the shortcut is listed with the
    /// suggestions on Chirp's bar. (A hint beside the cursor sat on top of the next line of the user's own text.)
    func offer(_ fix: Proofreading.SentenceFix, owner: String, apply: @escaping () -> Void) {
        guard Features.on(.write) else { return }
        self.apply = apply
        self.owner = owner
        count = fix.count
        let newKey = "\(owner)|\(fix.range)|\(fix.replacement)"
        guard newKey != key else { return }
        key = newKey
        KeyboardShortcuts.enable(.fixSentence)
        claimed = true
    }

    /// Takes the offer back, if it was `owner`'s.
    func withdraw(owner: String) {
        guard self.owner == owner, apply != nil || !key.isEmpty else { return }
        apply = nil
        key = ""
        count = 0
        KeyboardShortcuts.disable(.fixSentence)
        claimed = false
    }

    /// The shortcut was pressed: apply the offer, then take it back.
    func trigger() {
        guard Features.on(.write), let apply else { return }
        Log.write("write", "fix sentence: \(count) fixes (\(owner))")
        let who = owner
        apply()
        withdraw(owner: who)
    }
}
