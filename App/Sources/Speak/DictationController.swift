import AVFoundation
import AppKit
import ChirpCore
import ChirpML
import KeyboardShortcuts
import Observation
import SwiftUI

/// The global shortcuts for dictation. The user can change them in Settings.
extension KeyboardShortcuts.Name {
    /// Hands-free dictation: press once to start, again to stop. (Holding the hold key is the usual way.)
    static let dictate = Self("dictate", initial: .init(.space, modifiers: [.option]))
    /// Types the last dictation again. With the right Option key only (see `ShortcutLayout`).
    static let pasteLast = Self("pasteLast", initial: .init(.p, modifiers: [.option]))
}

/// How the dictation shortcut behaves. It is press to start and press to stop (`toggle`); the other two
/// are left for test runs (`key?mode=hold`), since holding to talk is the hold key's job now.
enum ActivationMode: String {
    case holdOrToggle
    case hold
    case toggle
}

/// A single key that can be held to talk.
enum HoldKey: String, CaseIterable, Identifiable, Codable {
    case none, fn, rightOption, rightCommand

    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: "None"
        case .fn: "Fn (Globe)"
        case .rightOption: "Right Option"
        case .rightCommand: "Right Command"
        }
    }

    /// The key's hardware code, as it arrives in key events.
    var keyCode: UInt16? {
        switch self {
        case .none: nil
        case .fn: 63
        case .rightOption: 61
        case .rightCommand: 54
        }
    }

    /// The modifier flag that is set while the key is down.
    var flag: NSEvent.ModifierFlags {
        switch self {
        case .none: []
        case .fn: .function
        case .rightOption: .option
        case .rightCommand: .command
        }
    }
}

/// Watches one modifier key being held on its own. Needs Accessibility permission to see keys
/// pressed in other apps; without it the key simply does nothing.
@MainActor
final class HoldKeyMonitor {
    var onDown: (() -> Void)?
    var onUp: (() -> Void)?
    /// Called in place of `onUp` when another key was pressed while this one was down: it was being used
    /// as an ordinary modifier (Option+E), not held to talk. Falls back to `onUp` when not set.
    var onCancel: (() -> Void)?
    /// The key went down on its own, and came up again, whatever was pressed in between. For the
    /// shortcuts that only answer while the right Option key is down (`ShortcutLayout`).
    var onHeld: (() -> Void)?
    var onReleased: (() -> Void)?
    /// Watches whether or not Dictate is switched on (the shortcut watcher; the hold key follows Dictate).
    var followsDictate = true
    var key: HoldKey = .none {
        didSet { install() }
    }
    private var monitors: [Any] = []
    /// True while the key is being watched for.
    var isWatching: Bool { !monitors.isEmpty }
    private var isDown = false
    /// True from the key going down on its own until it comes up.
    private var held = false
    /// Waits for Accessibility to be allowed, then sets up again.
    private var waiter: Task<Void, Never>?

    /// Sets up the key watchers again for the chosen key, removing the old ones.
    private func install() {
        waiter?.cancel()
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        isDown = false
        if held {
            held = false
            onReleased?()
        }
        guard key != .none, !LinkHandler.noGlobalShortcuts, !followsDictate || Features.on(.dictate) else { return }
        if !AXIsProcessTrusted() {
            // Keys in other apps are only visible once Accessibility is allowed. Set up again when it is.
            waiter = Task { [weak self] in
                while !Task.isCancelled, !AXIsProcessTrusted() { try? await Task.sleep(for: .seconds(2)) }
                guard !Task.isCancelled else { return }
                Log.write("speak", "Accessibility allowed: hold key is active")
                self?.install()
            }
        }
        let handle: (NSEvent) -> Void = { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown], handler: handle) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown], handler: { event in
            handle(event)
            return event
        }) {
            monitors.append(local)
        }
    }

    /// Works out from one key event whether the hold key went down on its own or came up.
    private func handle(_ event: NSEvent) {
        guard let code = key.keyCode else { return }
        if event.type == .keyDown {
            // The key is being used as a normal modifier (e.g. Option+E): that is not dictation.
            if isDown {
                isDown = false
                (onCancel ?? onUp)?()
            }
            return
        }
        guard event.keyCode == code else { return }
        let pressed = event.modifierFlags.contains(key.flag)
        // Only when it is the sole modifier held.
        let others = event.modifierFlags.intersection([.command, .option, .control, .shift, .function]).subtracting(key.flag)
        if pressed, !held, others.isEmpty {
            held = true
            onHeld?()
        } else if !pressed, held {
            held = false
            onReleased?()
        }
        if pressed, !isDown, others.isEmpty {
            isDown = true
            onDown?()
        } else if !pressed, isDown {
            isDown = false
            onUp?()
        }
    }
}

/// Where the finished text goes.
enum DictationTarget: Equatable {
    /// Typed into the app the user is working in.
    case frontApp
    /// Handed back to Chirp's own window (the "try it" box).
    case inApp
    /// Into the note open in the perch, a piece at a time as the words are heard (`listenForNote`).
    /// Never into the app in front.
    case note
}

/// What happened when a new note asked to be listened to.
enum NoteListening: Equatable {
    /// Listening: the words go into the note as they are heard.
    case started
    /// Dictate is switched off.
    case off
    /// A dictation, or turning one into text, is already under way.
    case busy
    /// macOS has not asked about the microphone yet.
    case microphoneNotAsked
    /// The microphone is not allowed.
    case microphoneDenied
    /// The microphone could not be opened; the reason has been shown.
    case failed
}

/// Runs a dictation from key press to inserted text. What was said is cleaned up by rule
/// (`DictationPipeline`: filler words, restated words, spoken lists, the dictionary) and typed; the
/// language model has no part in it.
@MainActor
@Observable
final class DictationController {
    /// Where a dictation is: not running, listening, or turning speech into text.
    enum Phase: Equatable {
        case idle
        case recording
        case transcribing
    }

    private(set) var phase: Phase = .idle
    /// Recent audio levels for the wire, oldest first.
    private(set) var levels: [Double] = Array(repeating: 0, count: 28)
    /// Seconds recorded in the current dictation.
    private(set) var elapsed: Double = 0
    /// A short notice, e.g. "Copied. Press ⌘V to paste."
    private(set) var notice: String?
    /// The most recent result, for the in-app "try it" box.
    private(set) var lastText: String = ""
    /// Bumped whenever history changes, so lists reload.
    private(set) var historyVersion = 0
    /// Words learned from the most recent edit, for the page to announce.
    var lastLearned: [String] = []
    /// How long the last transcription took (diagnostics).
    private var lastSeconds: Double = 0
    /// How long each part of the speech model took to load (diagnostics).
    private var loadTimings: [String: Double] = [:]

    /// How the Dictate shortcut behaves: press to start, press again to stop. Not a setting; a test run
    /// can change it for its own length.
    var mode: ActivationMode = .toggle
    /// Whether each dictation's audio is kept, so it can be played or transcribed again.
    var keepAudio: Bool {
        didSet { try? app.engine.setSetting("keepDictationAudio", keepAudio) }
    }
    /// How many past dictations are kept.
    var historyLimit: Int {
        didSet { try? app.engine.setSetting("dictationHistoryLimit", historyLimit) }
    }
    /// Keeps the microphone open between dictations so the first word is never clipped.
    var keepMicReady: Bool {
        didSet {
            try? app.engine.setSetting("keepMicReady", keepMicReady)
            applyMicReady()
        }
    }
    /// A single key that works as hold-to-talk, in addition to the shortcut.
    var holdKey: HoldKey {
        didSet {
            try? app.engine.setSetting("holdKey", holdKey)
            holdKeyMonitor.key = holdKey
        }
    }
    /// Long dictations are transcribed in pieces of about this many seconds while the user is still
    /// talking, so the wait at the end stays short. 0 turns it off.
    var pieceSeconds: Int {
        didSet { try? app.engine.setSetting("longDictationPieceSeconds", pieceSeconds) }
    }
    private let holdKeyMonitor = HoldKeyMonitor()

    private let app: AppModel
    private let models: ModelCenter
    private let library: Library
    private let recorder = AudioRecorder()
    private let fullSpeed = FullSpeed()

    /// Where the current dictation's text will go.
    private var target: DictationTarget = .frontApp
    /// The app the user was in when the dictation began.
    private var context = WorkContext()
    /// When the shortcut went down, to tell a tap from a hold.
    private var keyDownAt: Date?
    /// True while listening continues until stopped by hand.
    private var handsFree = false
    /// Updates the clock while listening.
    private var ticker: Task<Void, Never>?
    /// The transcription under way after Stop, so Cancel can end it.
    private var work: Task<Void, Never>?
    /// When listening stopped, to time the wait for the text.
    private var stoppedAt = Date()
    /// Watches for Esc while listening, to cancel.
    private var escapeMonitor: Any?
    /// True while the hold key started the current dictation and is still down.
    private var holdKeyDown = false
    /// When the hold key went down, to tell a slip of the modifier from a dictation.
    private var holdKeyDownAt = Date()

    /// Opens or closes the standing-by microphone to match the setting.
    private func applyMicReady() {
        if keepMicReady, Features.on(.dictate) {
            // Only once the microphone is allowed; never trigger the permission prompt from here.
            if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized { try? recorder.standBy() }
        } else {
            recorder.endStandBy()
        }
    }

    init(app: AppModel, models: ModelCenter) {
        self.app = app
        self.models = models
        library = Library(store: app.store)
        keepAudio = (try? app.engine.setting("keepDictationAudio", as: Bool.self)) ?? true
        historyLimit = (try? app.engine.setting("dictationHistoryLimit", as: Int.self)) ?? 200
        keepMicReady = (try? app.engine.setting("keepMicReady", as: Bool.self)) ?? false
        // Holding Right Option alone is how dictation starts, unless another key (or none) was chosen.
        holdKey = (try? app.engine.setting("holdKey", as: HoldKey.self)) ?? .rightOption
        pieceSeconds = (try? app.engine.setting("longDictationPieceSeconds", as: Int.self)) ?? 25

        recorder.onLevel = { [weak self] level in
            Task { @MainActor in self?.push(level: level) }
        }
        registerShortcuts()
        holdKeyMonitor.onDown = { [weak self] in
            guard let self else { return }
            guard self.phase == .idle else {
                if self.isBusy { self.rememberPress(mode: .hold, tag: Self.holdKeyTag, target: .frontApp) }
                return
            }
            self.holdKeyDown = true
            self.holdKeyDownAt = Date()
            // The start sound waits a moment when the key may be the start of a shortcut (right ⌥ N), so
            // a shortcut makes no sound. Listening itself starts at once.
            self.start(target: self.practice ? .inApp : .frontApp, soundAfter: self.holdKey == .rightOption ? 0.3 : 0)
        }
        holdKeyMonitor.onCancel = { [weak self] in
            guard let self else { return }
            // Used as an ordinary modifier while Chirp was busy: not a press to remember.
            if self.isBusy, self.waitingPress.waiting?.tag == Self.holdKeyTag { self.waitingPress.cancel() }
            guard self.holdKeyDown else { return }
            self.holdKeyDown = false
            guard self.phase == .recording else { return }
            // Another key straight after the hold key is a shortcut such as Option+E, not dictation: nothing
            // is typed. Later on it is a slip while talking, and what was said is kept.
            if Date().timeIntervalSince(self.holdKeyDownAt) < ShortcutKeys.shortcutWindow { self.cancel() } else { self.finish() }
        }
        holdKeyMonitor.onUp = { [weak self] in
            guard let self else { return }
            if self.isBusy { self.waitingPress.keyUp(mode: .hold, tag: Self.holdKeyTag, tapSeconds: Self.tapSeconds) }
            guard self.holdKeyDown else { return }
            self.holdKeyDown = false
            if self.phase == .recording { self.finish() }
        }
        holdKeyMonitor.key = holdKey
        ShortcutLayout.holdDictates = { [weak self] in self?.holdKey == .rightOption && Features.on(.dictate) }
        ShortcutLayout.holdWasShortcut = { [weak self] in self?.holdWasShortcut() }
        applyMicReady()
        LinkHandler.commands["dictate"] = { [weak self] q in
            self?.start(target: q["target"] == "front" ? .frontApp : .inApp)
        }
        // The shortcut itself, for test runs: `key?down=1` and `key?up=1`, and `key?mode=hold` (`toggle`,
        // `holdOrToggle`) to choose how it behaves for this run.
        LinkHandler.commands["key"] = { [weak self] q in
            guard let self else { return }
            if let mode = q["mode"].flatMap(ActivationMode.init(rawValue:)) { self.mode = mode }
            // `hold=<seconds>` presses and lets go that much later, timed here and not by two links.
            if let hold = q["hold"].flatMap(Double.init) {
                self.keyDown(target: .inApp, tag: 0)
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(hold))
                    self?.keyUp(tag: 0)
                }
                return
            }
            if q["down"] == "1" { self.keyDown(target: .inApp, tag: 0) }
            if q["up"] == "1" { self.keyUp(tag: 0) }
        }
        // The hold key, for test runs: `hold-key?down=1`, `hold-key?up=1`, and `hold-key?chord=1` for a
        // shortcut's letter pressed while it is down. `state` has `dictation.holdKey`.
        LinkHandler.commands["hold-key"] = { [weak self] q in
            guard let self else { return }
            if q["down"] == "1" { self.holdKeyMonitor.onDown?() }
            if q["chord"] == "1" { self.holdWasShortcut() }
            if q["up"] == "1" { self.holdKeyMonitor.onUp?() }
        }
        // "Transcribe again" on the newest dictation that was kept with its audio and no words.
        LinkHandler.commands["retranscribe-kept"] = { [weak self] _ in
            guard let self, let item = self.history(kinds: [.dictation]).first(where: { $0.body.isEmpty && $0.audioFile != nil }) else { return }
            Task { await self.retranscribe(item) }
        }
        LinkHandler.commands["stop"] = { [weak self] _ in self?.finish() }
        LinkHandler.commands["cancel"] = { [weak self] _ in self?.cancel() }
        // A link in place of a file; `link-choose?n=0` picks from a feed's episodes, `link-cancel` stops a download.
        LinkHandler.commands["transcribe-link"] = { [weak self] q in if let self { LinkImporter.shared.start(q["url"] ?? "", dictation: self) } }
        LinkHandler.commands["link-choose"] = { q in
            let links = LinkImporter.shared
            if let n = Int(q["n"] ?? ""), let episodes = links.choice?.episodes, episodes.indices.contains(n) { links.choose(episodes[n]) }
        }
        LinkHandler.commands["link-cancel"] = { _ in LinkImporter.shared.cancel() }
        // The Settings row's buttons, and Cancel on an import at whatever stage it is.
        LinkHandler.commands["link-tool"] = { q in q["do"] == "remove" ? LinkImporter.shared.removeTool() : LinkImporter.shared.downloadOrUpdateTool() }
        LinkHandler.commands["import-cancel"] = { [weak self] _ in self?.cancelImport() }
        LinkHandler.commands["link-ask"] = { q in
            LinkImporter.shared.typed = q["text"] ?? ""
            LinkImporter.shared.asking = q["show"] != "0"
        }
        LinkHandler.stateProviders["links"] = { [weak self] in
            let links = LinkImporter.shared
            return ["phase": "\(links.phase)", "line": links.line, "problem": links.lastProblem, "title": links.lastTitle,
                    "tool": links.toolVersion ?? "", "toolNote": links.toolNote, "importing": self?.importStatus.map { "\($0.name) | \($0.line)" } ?? "",
                    "episodes": links.choice?.episodes.map(\.title) ?? [], "podcast": links.choice?.podcast ?? ""] as [String: Any]
        }
        LinkHandler.commands["transcribe"] = { [weak self] q in
            guard let path = q["path"] else { return }
            Task { await self?.transcribe(file: URL(fileURLWithPath: path)) }
        }
        LinkHandler.commands["editlast"] = { [weak self] q in
            guard let self, let item = self.history(kinds: [.dictation]).first(where: { !$0.body.isEmpty }), let text = q["text"] else { return }
            self.lastLearned = self.saveEdit(of: item, newText: text)
        }
        LinkHandler.stateProviders["dictation"] = { [weak self] in
            guard let self else { return [:] }
            return ["phase": "\(self.phase)", "lastText": self.lastText, "notice": self.notice ?? "",
                    "dictations": self.history(kinds: [.dictation]).map(\.body),
                    "voiceNotes": self.history(kinds: [.voiceNote]).map { item in
                        (item.id.flatMap { try? self.library.segments(itemID: $0) } ?? []).map(\.text).joined(separator: " ")
                    },
                    "learned": self.lastLearned, "seconds": self.lastSeconds, "loadTimings": self.loadTimings,
                    // Dictations kept with their audio and no words (nothing came back, or it failed).
                    "keptWithoutWords": self.history(kinds: [.dictation]).filter { $0.body.isEmpty && $0.audioFile != nil }.count,
                    "waited": self.lastWaited, "finished": self.finishedCount,
                    "engineRuns": self.models.transcriber.runCount, "workerStarts": self.models.transcriber.workerStarts,
                    "backend": self.models.transcriber.backendNow,
                    "holdKey": self.holdKey.rawValue, "mode": self.mode.rawValue, "starts": self.startCount,
                    "target": "\(self.target)", "forNote": self.isNoteDictation, "handsFree": self.handsFree]
        }
        // Have the speech model in memory before the first dictation, so it starts instantly.
        if Transcriber.isDownloaded, Features.on(.dictate) {
            Task { try? await models.ensure(.transcription) }
        }
        Features.shared.whenChanged { [weak self] old, new in
            guard let self, old.isOn(.dictate) != new.isOn(.dictate) else { return }
            // Switched off while listening or turning speech into text: that dictation is dropped, as Cancel does.
            // (A file or link being transcribed belongs to Record and is left alone.)
            if !new.isOn(.dictate), self.importName == nil { self.cancel() }
            // The hold key is watched, and the microphone kept standing by, only while Dictate is on.
            self.holdKeyMonitor.key = self.holdKey
            self.applyMicReady()
        }
        Features.shared.whenChanged { [weak self] old, new in
            // Record switched off while a file or a link is being transcribed: stopped, as Cancel does.
            if old.records, !new.records { self?.cancelImport() }
        }
        Features.shared.probe("dictate.holdKeyWatched") { [weak self] in self?.holdKeyMonitor.isWatching ?? false }
        Features.shared.probe("dictate.micStandingBy") { [weak self] in (self?.keepMicReady ?? false) && Features.on(.dictate) }
    }

    // MARK: Shortcuts

    /// Connects each global shortcut to what it does.
    private func registerShortcuts() {
        KeyboardShortcuts.onKeyDown(for: .dictate) { [weak self] in self?.keyDown(tag: 0) }
        KeyboardShortcuts.onKeyUp(for: .dictate) { [weak self] in self?.keyUp(tag: 0) }
        KeyboardShortcuts.onKeyDown(for: .pasteLast) { [weak self] in self?.pasteLast() }
    }

    /// A shortcut's letter was pressed while the hold key was down (right ⌥ N): the hold was the start of
    /// that shortcut, not a dictation. What the hold began is dropped: nothing is typed and nothing is said.
    func holdWasShortcut() {
        if isBusy, waitingPress.waiting?.tag == Self.holdKeyTag { waitingPress.cancel() }
        guard holdKeyDown else { return }
        holdKeyDown = false
        if phase == .recording {
            Log.write("speak", "the hold key was the start of a shortcut: that dictation is dropped")
            cancel()
        }
    }

    /// The hold key that is in use now, for the perch and the menu bar to name ("hold ⌥"); nil when
    /// dictation starts only from the shortcut.
    var holdKeyInUse: HoldKey? { holdKey == .none ? nil : holdKey }

    /// Types the most recent dictation again, for when it went to the wrong place or was lost.
    func pasteLast() {
        guard Features.on(.dictate) else { return }
        // Pressed as right ⌥ P: the hold that began it is not a dictation.
        holdWasShortcut()
        // The newest one that has words: a dictation kept only for its audio has nothing to type.
        guard phase == .idle, let last = history(kinds: [.dictation]).first(where: { !$0.body.isEmpty }) else {
            Toast.show("Nothing dictated yet.")
            return
        }
        Task {
            if await TextInserter.insert(last.body + " ") == .copiedOnly {
                Toast.show("Copied. Press ⌘V to paste. To have Chirp type for you, allow Accessibility in System Settings.", seconds: 6)
            }
        }
    }

    /// The shortcut went down: starts a dictation, or ends one that is running hands-free. While the last
    /// dictation is still being turned into text the press is remembered (see `WaitingPress`).
    private func keyDown(target: DictationTarget = .frontApp, tag: Int) {
        guard Features.on(.dictate) else { return }
        switch phase {
        case .idle:
            keyDownAt = Date()
            handsFree = mode == .toggle
            start(target: practice ? .inApp : target)
        case .recording:
            if holdKeyDown {
                // Right Option, then Space: the hold becomes hands-free, so letting go keeps listening
                // and the next press stops. (Without this the hold ended as the keys came up, with
                // nothing said.)
                holdKeyDown = false
                handsFree = true
            } else if handsFree {
                // A press while recording hands-free ends it.
                finish()
            }
        case .transcribing:
            rememberPress(mode: pressMode, tag: tag, target: target)
        }
    }

    /// The shortcut came up: ends a held dictation, or after a quick tap leaves it running hands-free.
    private func keyUp(tag: Int) {
        if isBusy { waitingPress.keyUp(mode: pressMode, tag: tag, tapSeconds: Self.tapSeconds) }
        guard phase == .recording, let down = keyDownAt else { return }
        keyDownAt = nil
        switch mode {
        case .toggle: break
        case .hold: finish()
        case .holdOrToggle:
            // A quick tap means "keep listening until I tap again".
            if Date().timeIntervalSince(down) < Self.tapSeconds { handsFree = true } else { finish() }
        }
    }

    // MARK: A press while busy (remembered until it can be acted on)

    /// A key let go sooner than this was a tap, not a hold.
    private static let tapSeconds = 0.3
    /// The single hold key, among the shortcuts a press can be remembered for.
    private static let holdKeyTag = 3
    /// A press that came while the last dictation was still being turned into text.
    private var waitingPress = WaitingPress()
    /// What that press asked for.
    private var waitingRequest: DictationTarget?
    /// Turning speech into text: not listening and not free.
    private var isBusy: Bool { phase == .transcribing }

    private var pressMode: PressMode {
        switch mode {
        case .hold: .hold
        case .toggle: .toggle
        case .holdOrToggle: .holdOrToggle
        }
    }

    /// Notes a press made while busy, so listening starts when the work under way ends.
    private func rememberPress(mode: PressMode, tag: Int, target: DictationTarget) {
        let had = waitingPress.waiting
        waitingPress.keyDown(mode: mode, tag: tag)
        if had == nil, waitingPress.waiting != nil {
            waitingRequest = target
            Log.write("speak", "a press while busy is remembered")
        }
    }

    /// Starts the dictation a remembered press asked for, now that the last one is done.
    private func startWaitingPress() {
        guard phase == .idle, let next = waitingPress.take(), let request = waitingRequest else { return }
        waitingRequest = nil
        Log.write("speak", "starting the remembered press (\(next.handsFree ? "hands-free" : "held"))")
        start(target: practice ? .inApp : request)
        guard phase == .recording else { return }
        if next.tag == Self.holdKeyTag {
            holdKeyDown = true
            holdKeyDownAt = next.pressedAt
        } else {
            handsFree = next.handsFree
            // A key still held is measured from when it really went down.
            keyDownAt = next.handsFree ? nil : next.pressedAt
        }
    }

    /// While true (the first-run "try it" step), the shortcut shows the words in Chirp and types nowhere.
    var practice = false

    /// True while listening continues until stopped by hand (no key is being held).
    var isHandsFree: Bool { handsFree }

    /// Starts listening from a click (the perch or the menu bar): it keeps going until stopped.
    func startHandsFree() {
        guard phase == .idle else { return }
        // The same as the shortcut: kept inside Chirp during the first-run practice.
        start(target: practice ? .inApp : .frontApp)
        if phase == .recording { handsFree = true }
    }

    // MARK: Dictating into a new note

    /// Where a note's dictation sends its words, cleaned up, as each piece is ready. Nil when the
    /// dictation under way is not a note's.
    private var noteWords: ((String) -> Void)?
    /// Told once a note's dictation is over: its last words are in, or it was cancelled.
    private var noteDone: (() -> Void)?
    /// What a note's dictation has put in so far, cleaned up and as heard, for its history row.
    private var noteTexts: [String] = []
    private var noteRaw: [String] = []

    /// True while a note's dictation is listening or putting in its last words.
    var isNoteDictation: Bool { noteWords != nil }

    /// Starts listening for a new note, hands-free: `words` is given the words a piece at a time while the
    /// user is still talking, and `done` is told when the last of them are in. The Dictate shortcut, the
    /// perch's Stop and `finish()` end it as they end any dictation; Escape is left to the note.
    func listenForNote(words: @escaping (String) -> Void, done: @escaping () -> Void) -> NoteListening {
        guard Features.on(.dictate) else { return .off }
        guard phase == .idle else { return .busy }
        if AudioRecorder.feedFile == nil {
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .notDetermined: return .microphoneNotAsked
            case .denied, .restricted: return .microphoneDenied
            default: break
            }
        }
        noteWords = words
        noteDone = done
        noteTexts = []
        noteRaw = []
        start(target: .note)
        guard phase == .recording else {
            noteWords = nil
            noteDone = nil
            return .failed
        }
        handsFree = true
        return .started
    }

    /// Cleans up one piece of a note's dictation by rule and hands it to the note.
    private func deliverNote(_ raw: String) {
        let heard = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !heard.isEmpty, let words = noteWords else { return }
        let text = ((try? DictationPipeline(engine: app.engine))?.process(heard, app: .other) ?? heard)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        noteRaw.append(heard)
        noteTexts.append(text)
        words(text)
    }

    /// The note's dictation is over: the note is told, once.
    private func endNote() {
        let done = noteDone
        noteWords = nil
        noteDone = nil
        done?()
    }

    // MARK: Lifecycle

    /// Starts listening. Asks for the microphone first if macOS has not asked yet, and says why if it cannot start.
    /// `soundAfter` holds the start sound back that many seconds, and skips it if listening has ended by then.
    func start(target: DictationTarget, soundAfter: Double = 0) {
        guard phase == .idle, Features.on(.dictate) else { return }
        self.target = target
        notice = nil
        let front = NSWorkspace.shared.frontmostApplication
        context = WorkContext(bundleID: front?.bundleIdentifier, appName: front?.localizedName)
        Log.write("speak", "start: target \(target), front app \(front?.bundleIdentifier ?? "?"), speech model \(models.state(.transcription))")
        // The first time, macOS has to ask about the microphone. Ask now rather than record silence.
        if AudioRecorder.feedFile == nil, AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            Task { [weak self] in
                let allowed = await AVCaptureDevice.requestAccess(for: .audio)
                self?.flash(allowed ? "Microphone allowed. Go ahead and dictate." : AudioRecorder.RecorderError.microphoneDenied.localizedDescription)
            }
            return
        }
        do {
            try recorder.start()
        } catch {
            flash(error.localizedDescription, seconds: 5)
            return
        }
        phase = .recording
        app.mood = .listening
        fullSpeed.begin("Dictation")
        startCount += 1
        if soundAfter > 0 {
            let run = startCount
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(soundAfter))
                if let self, self.phase == .recording, self.startCount == run { Sounds.start() }
            }
        } else {
            Sounds.start()
        }
        elapsed = 0
        levels = Array(repeating: 0, count: levels.count)
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, self.phase == .recording else { return }
                self.elapsed = self.recorder.duration
            }
        }
        // Into a note, Escape closes the note and keeps what was said (the perch's own monitors see it).
        if target != .note {
            escapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
                if event.keyCode == 53 { Task { @MainActor in self?.cancel() } }
            }
        }
        // Make sure the speech model is loaded by the time the user stops talking, and
        // keep it loaded for as long as this recording lasts.
        startPieces()
        holding = true
        Task { [models, weak self] in
            await models.transcriber.hold()
            self?.holdApplied = true
            try? await models.ensure(.transcription)
        }
    }

    /// How many dictations have started listening (diagnostics, and which one a late start sound belongs to).
    private var startCount = 0

    /// True once the hold above has been counted by the speech model (it waits behind a run in progress).
    private var holdApplied = false

    /// True while this dictation is keeping the speech model loaded.
    private var holding = false
    /// How long the last dictation waited from stop to text, and how many have finished (diagnostics).
    private var lastWaited: Double = 0
    private var finishedCount = 0

    // MARK: Long dictations (transcribed in pieces)

    /// Text of the pieces already transcribed while the user was talking, in order.
    private var pieceTexts: [String] = []
    /// Audio before this sample is already in `pieceTexts`.
    private var decodedSamples = 0
    /// Voice detection or a piece failed: the whole recording is transcribed in one pass instead.
    private var piecesFailed = false
    /// The loop that transcribes pieces while recording goes on.
    private var pieceWorker: Task<Void, Never>?
    /// Which dictation the pieces belong to, so a piece that finishes late never lands in the next one.
    /// It also says which job owns `phase`: it moves on at every start and every cancel, and a job that
    /// finds it has moved on leaves the phase, the overlay and the pieces alone.
    private var pieceRun = 0
    /// The pieces are not looked for again until this much audio has been recorded. Set after a look that
    /// cut nothing (the user was pausing), so a long silence is not searched from its start every second.
    private var nextPieceCheck = 0

    /// Clears the last dictation's pieces and starts the loop that transcribes this one's as it goes.
    private func startPieces() {
        pieceRun += 1
        pieceTexts = []
        decodedSamples = 0
        piecesFailed = false
        nextPieceCheck = 0
        // A note shows its words as they are heard, whatever the setting for long dictations says.
        let live = target == .note
        guard pieceSeconds > 0 || live else { return }
        pieceWorker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(live ? 500 : 1000))
                guard let self, self.phase == .recording, !Task.isCancelled else { return }
                if live { await self.transcribeLivePiece() } else { await self.transcribeReadyPieces() }
            }
        }
    }

    /// For a note: transcribes the phrase just finished, if there is one, and puts its words in the note.
    private func transcribeLivePiece() async {
        let from = decodedSamples
        let run = pieceRun
        let pending = recorder.samples(from: from)
        guard !piecesFailed, pending.count >= LiveCut.rate / 2 else { return }
        guard (try? await models.ensure(.transcription)) != nil, let speech = await models.transcriber.speechSegments(pending) else {
            // Without voice detection there is nowhere safe to cut: the words all come when listening stops.
            piecesFailed = true
            return
        }
        guard run == pieceRun, phase != .idle else { return }
        switch LiveCut().next(speech: speech, samples: pending.count) {
        case .wait:
            return
        case .skip(let cut):
            decodedSamples = from + min(cut, pending.count)
        case .transcribe(let cut):
            let upTo = min(cut, pending.count)
            let began = Date()
            guard let piece = try? await models.transcriber.transcribe(Array(pending[..<upTo])) else {
                piecesFailed = true
                return
            }
            guard run == pieceRun, phase != .idle else { return }
            decodedSamples = from + upTo
            Log.write("speak", String(format: "note piece: %.1f s of audio in %.2f s, while listening", Double(upTo) / 16_000, Date().timeIntervalSince(began)))
            deliverNote(piece.text)
        }
    }

    /// Cuts off and transcribes whatever is ready while recording goes on.
    private func transcribeReadyPieces() async {
        let plan = LongForm(targetSeconds: Double(pieceSeconds))
        // Nothing is cut until there is audio past the longest piece, so the cut is not a guess.
        let available = recorder.sampleCount
        guard !piecesFailed, available >= nextPieceCheck,
            available - decodedSamples > plan.maxSamples + plan.lookaheadSamples
        else { return }
        // If this look cuts nothing, the next waits for three more seconds of audio.
        nextPieceCheck = available + 3 * LongForm.rate
        let from = decodedSamples
        let run = pieceRun
        let pending = recorder.samples(from: from)
        guard (try? await models.ensure(.transcription)) != nil, let speech = await models.transcriber.speechSegments(pending) else {
            piecesFailed = true
            return
        }
        // While the user is in a pause its length is not known yet; wait until they are talking again.
        guard let last = speech.last, pending.count - last.upperBound < LongForm.rate / 4 else { return }
        var done = 0
        for cut in plan.cuts(LongForm.candidates(speech: speech, samples: pending.count), samples: pending.count) {
            guard pending.count - done > plan.maxSamples + plan.lookaheadSamples else { break }
            let began = Date()
            guard let piece = try? await models.transcriber.transcribe(Array(pending[done..<cut])) else {
                piecesFailed = true
                return
            }
            guard run == pieceRun, phase != .idle else { return }
            pieceTexts.append(piece.text)
            Log.write("speak", String(format: "piece %d: %.1f s of audio in %.2f s, while listening", pieceTexts.count, Double(cut - done) / 16_000, Date().timeIntervalSince(began)))
            done = cut
            decodedSamples = from + cut
            nextPieceCheck = 0
        }
    }

    /// Transcribes what the pieces have not covered and returns the whole text.
    private func transcribeAll(_ samples: [Float]) async throws -> Transcript {
        let worker = pieceWorker
        await worker?.value
        // A newer dictation may have begun meanwhile (this one was cancelled): its worker is not this one's to drop.
        if pieceWorker == worker { pieceWorker = nil }
        try Task.checkCancellation()
        let duration = Double(samples.count) / 16_000
        let plan = LongForm(targetSeconds: Double(max(pieceSeconds, 10)))
        guard pieceSeconds > 0, !piecesFailed, decodedSamples <= samples.count,
            !pieceTexts.isEmpty || samples.count > plan.maxSamples
        else { return try await transcribeWithRecovery(samples) }
        let rest = Array(samples[decodedSamples...])
        var texts = pieceTexts
        var from = 0
        // What is left can itself be longer than one piece (the recording stopped before it was cut).
        if rest.count > plan.maxSamples, let speech = await models.transcriber.speechSegments(rest) {
            for cut in plan.cuts(LongForm.candidates(speech: speech, samples: rest.count), samples: rest.count) {
                texts.append(try await transcribeWithRecovery(Array(rest[from..<cut])).text)
                from = cut
            }
        }
        if from < rest.count { texts.append(try await transcribeWithRecovery(Array(rest[from...])).text) }
        if texts.count > 1 { Log.write("speak", String(format: "%.1f s of audio in %d pieces, %d of them while listening", duration, texts.count, pieceTexts.count)) }
        return Transcript(text: LongForm.join(texts), duration: duration)
    }

    /// Stops listening and turns the audio into text.
    func finish() {
        guard phase == .recording else { return }
        let samples = recorder.stop()
        Log.write("speak", String(format: "stop: %.1f s of audio, level %.4f", Double(samples.count) / 16_000, PauseSegmenter.rms(samples[...])))
        Sounds.stop()
        endRecordingUI()
        stoppedAt = Date()
        // The piece loop stops at its next check; a piece already being transcribed is finished and kept.
        pieceWorker?.cancel()
        phase = .transcribing
        app.mood = .thinking
        let run = pieceRun
        // The audio is written as soon
        // as listening stops, so a dictation that fails or comes back with no words can still be played
        // and transcribed again.
        let audio = keepAudio ? Self.writeAudio(samples) : nil
        let forNote = target == .note
        work = Task { [weak self] in
            if forNote { await self?.processNote(samples, run: run, audio: audio) } else { await self?.process(samples, run: run, audio: audio) }
        }
    }

    /// Writes a dictation's audio into the audio folder, off the main thread, and gives the file's name
    /// (nil when it could not be written).
    private nonisolated static func writeAudio(_ samples: [Float]) -> Task<String?, Never> {
        Task.detached(priority: .utility) {
            let name = "dictation-\(Int(Date().timeIntervalSince1970 * 1000)).m4a"
            let url = ChirpStore.audioDirectory.appendingPathComponent(name)
            return (try? AudioFile.write(samples, to: url)) != nil ? name : nil
        }
    }

    /// Saves a dictation that has audio and no words: the model was asked and returned nothing, or it
    /// failed. The row can be played and transcribed again from the Library. True when it was saved.
    private func keepWithoutWords(audio: Task<String?, Never>?, duration: Double, why: String) async -> Bool {
        guard let audio, let name = await audio.value else { return false }
        do {
            try library.save(
                SavedItem(kind: .dictation, audioFile: name, duration: duration, appBundleID: target == .frontApp ? context.bundleID : nil))
            try? library.trimDictations(keep: historyLimit)
            historyVersion += 1
            Log.write("speak", "kept the audio of a dictation with no words (\(why)), to play or transcribe again")
            return true
        } catch {
            return false
        }
    }

    /// Throws the recording away.
    func cancel() {
        guard phase != .idle else { return }
        // They asked for quiet, not for a recording later.
        waitingPress.cancel()
        waitingRequest = nil
        work?.cancel()
        pieceWorker?.cancel()
        pieceWorker = nil
        // A transcription already with the engine is stopped, not waited for. Not while a
        // meeting recording is using the same engine: the run in progress may be its.
        if models.transcriber.holdsNow - (holdApplied ? 1 : 0) <= 0 { models.transcriber.cancelRun() }
        // Whatever is still running for this dictation no longer owns the phase.
        pieceRun += 1
        if phase == .recording { recorder.stop() }
        endRecordingUI()
        reset()
        endNote()
    }

    /// Takes down what only exists while listening: the clock, the hold on the speech model, the Esc watcher.
    private func endRecordingUI() {
        ticker?.cancel()
        ticker = nil
        if holding {
            holding = false
            Task { [models, weak self] in
                await models.transcriber.release()
                self?.holdApplied = false
            }
        }
        handsFree = false
        keyDownAt = nil
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
    }

    /// Back to idle.
    private func reset() {
        phase = .idle
        app.mood = .idle
        fullSpeed.end()
    }

    /// From recorded audio to inserted text: transcribe, apply the user's rules, insert,
    /// then keep the audio and the history.
    private func process(_ samples: [Float], run: Int, audio: Task<String?, Never>?) async {
        // `run` is the dictation this audio belongs to. A cancelled dictation's transcription ends later,
        // perhaps after the next dictation has begun: only the dictation that still owns the phase goes
        // back to idle (and then starts a press that was remembered meanwhile).
        defer {
            finishedCount += 1
            if run == pieceRun {
                reset()
                startWaitingPress()
            }
        }
        // True once a history row has the audio file. Otherwise the file written at stop is removed.
        var kept = false
        defer {
            if !kept, let audio {
                Task.detached {
                    if let name = await audio.value { try? FileManager.default.removeItem(at: ChirpStore.audioDirectory.appendingPathComponent(name)) }
                }
            }
        }
        var duration = Double(samples.count) / 16_000
        do {
            var transcript: Transcript
            do {
                transcript = try await transcribeAll(samples)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                guard run == pieceRun else { throw CancellationError() }
                // If the pieces cannot be used, the whole recording is transcribed in one pass.
                Log.write("speak", "pieces failed (\(error.localizedDescription)); transcribing in one pass")
                transcript = try await transcribeWithRecovery(samples)
            }
            duration = transcript.duration
            let waited = Date().timeIntervalSince(stoppedAt)
            lastWaited = waited
            lastSeconds = await models.transcriber.lastProcessingTime
            loadTimings = await models.transcriber.loadTimings
            if let e = await models.transcriber.loadError { loadTimings[e] = -1 }
            try Task.checkCancellation()
            let raw = transcript.text
            Log.write("speak", String(format: "transcribed %d characters in %.2f s (last piece %.2f s)", raw.count, waited, lastSeconds))
            guard !raw.isEmpty else {
                flash(PauseSegmenter.rms(samples[...]) < 0.0005
                    ? "The microphone was silent. Check the input in System Settings › Sound."
                    : "Didn't catch anything")
                // Where the model was asked and gave no words, the audio is kept to try again. Where voice
                // detection found no speech at all there is nothing to keep.
                if transcript.heardSpeech {
                    kept = await keepWithoutWords(audio: audio, duration: duration, why: "no words came back")
                }
                return
            }
            var text = try DictationPipeline(engine: app.engine).process(
                raw, app: target == .frontApp ? AppKind(bundleID: context.bundleID) : .other)

            // A final "press enter" is an instruction, not words to type.
            var pressEnter = false
            if target == .frontApp { (text, pressEnter) = SpokenCommands.trailingEnter(text) }

            lastText = text

            switch target {
            case .frontApp where NoteTextView.focused?.hasKeyboard == true:
                // Into a note being written in Chirp itself: the same words, put in at the note's cursor
                // by its own editor rather than pasted, so undo takes them out. No audio goes with the note.
                NoteTextView.focused?.insertDictated(text)
            case .frontApp:
                // Spacing and the first capital depend on what is already around the cursor.
                let around = TextInserter.cursorContext()
                let outcome = await TextInserter.insert(Insertion.adapt(text, before: around?.before, after: around?.after))
                if pressEnter, outcome != .copiedOnly {
                    try? await Task.sleep(for: .milliseconds(200))
                    TextInserter.pressReturn()
                }
                if outcome == .copiedOnly {
                    flash("Copied. Press ⌘V to paste. To have Chirp type for you, allow Accessibility in System Settings.", seconds: 6)
                }
            case .inApp, .note:
                break
            }
            // The history comes after the words are on screen. The audio has been on its way since stop.
            let audioFile: String? = await audio?.value ?? nil
            try library.save(
                SavedItem(
                    kind: .dictation, body: text, rawText: raw, audioFile: audioFile,
                    duration: transcript.duration, appBundleID: target == .frontApp ? context.bundleID : nil))
            kept = audioFile != nil
            try? library.trimDictations(keep: historyLimit)
            historyVersion += 1
            // The "unload right after each use" setting. Not while a recording is holding the model.
            if ModelCenter.speechUnloadMinutes == 0, await models.transcriber.holds == 0 { await models.unload(.transcription) }

        } catch is CancellationError {
            // Cancelled: nothing to put in.
        } catch {
            Log.write("speak", "failed: \(error.localizedDescription)")
            // What was said is kept, with no words, so it can be transcribed again.
            kept = await keepWithoutWords(audio: audio, duration: duration, why: "transcription failed")
            guard run == pieceRun else { return }
            flash(error.localizedDescription, seconds: 5)
        }
    }

    /// After a note's dictation stops listening: transcribes what the pieces have not covered, puts those
    /// last words in the note, then keeps the whole dictation in the history as any other is kept.
    private func processNote(_ samples: [Float], run: Int, audio: Task<String?, Never>?) async {
        var kept = false
        defer {
            finishedCount += 1
            if !kept, let audio {
                Task.detached {
                    if let name = await audio.value { try? FileManager.default.removeItem(at: ChirpStore.audioDirectory.appendingPathComponent(name)) }
                }
            }
            // Only the dictation that still owns the phase goes back to idle; a cancel has told the note already.
            if run == pieceRun {
                reset()
                endNote()
                startWaitingPress()
            }
        }
        // A piece being transcribed when listening stopped is finished and put in first.
        let worker = pieceWorker
        await worker?.value
        if pieceWorker == worker { pieceWorker = nil }
        guard run == pieceRun else { return }
        let duration = Double(samples.count) / 16_000
        let rest = decodedSamples < samples.count ? Array(samples[decodedSamples...]) : []
        do {
            // What is left can be long when nothing could be cut while listening.
            let plan = LongForm(targetSeconds: Double(max(pieceSeconds, 10)))
            var from = 0
            if rest.count > plan.maxSamples, let speech = await models.transcriber.speechSegments(rest) {
                for cut in plan.cuts(LongForm.candidates(speech: speech, samples: rest.count), samples: rest.count) {
                    let piece = try await transcribeWithRecovery(Array(rest[from..<cut]))
                    guard run == pieceRun else { return }
                    deliverNote(piece.text)
                    from = cut
                }
            }
            if rest.count - from >= LiveCut.rate / 4 {
                let piece = try await transcribeWithRecovery(Array(rest[from...]))
                guard run == pieceRun else { return }
                deliverNote(piece.text)
            }
            lastWaited = Date().timeIntervalSince(stoppedAt)
            lastSeconds = await models.transcriber.lastProcessingTime
            let text = LongForm.join(noteTexts)
            Log.write("speak", String(format: "a note's dictation: %d pieces, %d characters, %.2f s after it stopped", noteTexts.count, text.count, lastWaited))
            // Nothing said (the user began typing straight away): there is nothing to keep, and nothing to say.
            guard !text.isEmpty else { return }
            lastText = text
            let audioFile: String? = await audio?.value ?? nil
            try library.save(
                SavedItem(kind: .dictation, body: text, rawText: LongForm.join(noteRaw), audioFile: audioFile, duration: duration, appBundleID: nil))
            kept = audioFile != nil
            try? library.trimDictations(keep: historyLimit)
            historyVersion += 1
            if ModelCenter.speechUnloadMinutes == 0, await models.transcriber.holds == 0 { await models.unload(.transcription) }
        } catch is CancellationError {
            // Cancelled: nothing more goes in.
        } catch {
            Log.write("speak", "a note's dictation failed: \(error.localizedDescription)")
            kept = await keepWithoutWords(audio: audio, duration: duration, why: "transcription failed")
            guard run == pieceRun else { return }
            flash(error.localizedDescription, seconds: 5)
        }
    }

    /// Transcribes one piece of audio. There is no time limit here, since waiting behind a model load is a
    /// place in the queue, not a failure: the worker's supervisor alone decides when a run is hung, stops it and tries again
    /// (`SpeechSupervisor.run`). A limit here could not stop the run; it only threw a slow answer away.
    private func transcribeWithRecovery(_ samples: [Float]) async throws -> Transcript {
        try await models.ensure(.transcription)
        do {
            return try await models.transcriber.transcribe(samples)
        } catch SpeechError.cancelled {
            throw CancellationError()
        }
    }

    // MARK: Files and history

    /// Transcribes an audio file into a recording in the library, like one made with Record.
    /// Returns true only when a transcript was saved.
    /// The file or link being transcribed, and how far along it is, in words; nil when none is. The perch's
    /// working bar and a row in the Library say it.
    var importStatus: (name: String, line: String)? {
        let links = LinkImporter.shared
        if links.isBusy, links.phase != .transcribing { return (links.name, links.line) }
        return importName.map { ($0, importLine) }
    }
    private var importName: String?
    private var importLine = ""
    /// The import's place in the line of jobs, while it waits its turn or runs.
    private var importJob: Int?
    /// True once Cancel was pressed on the import under way.
    private var importStopped = false

    /// Stops the file or link being transcribed, at whatever stage it is: nothing is saved.
    func cancelImport() {
        if LinkImporter.shared.isBusy, LinkImporter.shared.phase != .transcribing { return LinkImporter.shared.cancel() }
        guard importName != nil, !importStopped else { return }
        importStopped = true
        importLine = "Stopping"
        // The piece with the engine is stopped, not waited for; not while a meeting recording is using the
        // same engine (the import holds it once itself).
        if models.transcriber.holdsNow <= 1 { models.transcriber.cancelRun() }
        Log.write("speak", "an import was cancelled")
    }

    /// `title` and `source` are for sound fetched from a link (`LinkImporter`).
    @discardableResult
    /// `job` is the place a link already holds in the line of jobs; a file takes its own here.
    func transcribe(file url: URL, title: String? = nil, source: String? = nil, job held: Int? = nil) async -> Bool {
        guard Features.shared.set.records else { return false }
        // One job at a time: behind another file or link, or a meeting's notes, this one waits and says
        // what for. Nothing is refused. (A second import asked for while one waits is the one case that is.)
        let shown = title ?? url.deletingPathExtension().lastPathComponent
        let job = held ?? Jobs.shared.add("the file", title: shown)
        defer { if held == nil { Jobs.shared.done(job) } }
        // While it waits it has a row of its own in the Library, with Cancel (`Jobs.waitingImports`).
        guard await Jobs.shared.turn(job) else {
            PerchController.shared?.say("Stopped", seconds: 3)
            return false
        }
        // A dictation under way is never held up or cut off: the import starts when it has been typed.
        while phase != .idle { try? await Task.sleep(for: .milliseconds(200)) }
        importJob = job
        importName = shown
        importLine = "Transcribing"
        importStopped = false
        defer {
            importName = nil
            importJob = nil
        }
        phase = .transcribing
        app.mood = .thinking
        fullSpeed.begin("Transcribing a file")
        pieceRun += 1
        let run = pieceRun
        // If this was cancelled and something else has started, the phase is no longer this job's.
        defer { if run == pieceRun { reset() } }
        do {
            // In pieces, with a time on every line and the speakers told apart, like a recording made here.
            if let recorder = PerchController.shared?.recorder {
                guard let imported = try await recorder.importAudio(
                    url, title: title, source: source, stopped: { [weak self] in self?.importStopped ?? false },
                    step: { [weak self] in if self?.importStopped == false { self?.importLine = $0 } })
                else {
                    app.banner = "No speech was found in \(title ?? url.lastPathComponent)."
                    return false
                }
                // Someone else's words, transcribed from a file or a link, are a document: the transcript with
                // its times, the sound to play, and a summary only when asked for. No notes are written.
                TranscribedDocument.file(imported.id, link: source, file: url, in: library)
                historyVersion += 1
                app.libraryVersion += 1
                return true
            }
            try await models.ensure(.transcription)
            let transcript = try await models.transcriber.transcribe(file: url)
            guard !transcript.text.isEmpty else {
                app.banner = "No speech was found in \(url.lastPathComponent)."
                return false
            }
            let text = try DictationPipeline(engine: app.engine).process(transcript.text)
            let saved = try library.save(
                SavedItem(
                    kind: .voiceNote, title: title ?? url.deletingPathExtension().lastPathComponent,
                    rawText: transcript.text, duration: transcript.duration, source: source ?? url.path))
            if let id = saved.id {
                try library.replaceSegments(
                    itemID: id, with: [TranscriptSegment(itemID: id, speaker: "Speaker 1", start: 0, end: max(transcript.duration, 1), text: text)])
                TranscribedDocument.file(id, link: source, file: url, in: library)
            }
            historyVersion += 1
            app.libraryVersion += 1
            return true
        } catch is CancellationError {
            // Cancelled: nothing was saved and nothing is wrong.
            PerchController.shared?.say("Stopped", seconds: 3)
            return false
        } catch {
            app.report(error, doing: "transcribe \(url.lastPathComponent)")
            return false
        }
    }

    /// Runs the saved audio of a past dictation through transcription again (after a dictionary change, say).
    func retranscribe(_ item: SavedItem) async {
        guard let file = item.audioFile, phase == .idle else { return }
        phase = .transcribing
        pieceRun += 1
        let run = pieceRun
        defer { if run == pieceRun { reset() } }
        do {
            try await models.ensure(.transcription)
            let samples = try AudioFile.samples(from: ChirpStore.audioDirectory.appendingPathComponent(file))
            // Asked for by hand, so the model is asked whatever voice detection makes of the audio.
            let transcript = try await models.transcriber.transcribe(samples, gate: false)
            var updated = item
            updated.rawText = transcript.text
            updated.body = try DictationPipeline(engine: app.engine).process(transcript.text)
            try library.save(updated)
            historyVersion += 1
        } catch {
            app.report(error, doing: "transcribe that again")
        }
    }

    /// Saves an edit the user made to a past dictation and learns any word they corrected.
    /// Returns the words learned, to show the user.
    @discardableResult
    func saveEdit(of item: SavedItem, newText: String) -> [String] {
        var learned: [String] = []
        for (heard, meant) in WordDiff.substitutions(from: item.body, to: newText) {
            try? app.engine.noteCorrection(wrong: heard, right: meant)
            if let entry = try? app.engine.learnCorrection(
                heard: heard, meant: meant, note: "You changed “\(heard)” to “\(meant)” in a dictation")
            {
                learned.append(entry.term)
            }
        }
        var updated = item
        updated.body = newText
        _ = try? library.save(updated)
        historyVersion += 1
        return learned
    }

    func delete(_ item: SavedItem) {
        try? library.delete(item)
        historyVersion += 1
    }

    /// The most recent saved items of these kinds, newest first.
    func history(kinds: [ItemKind]) -> [SavedItem] {
        (try? library.items(kinds: kinds, limit: 300)) ?? []
    }

    // MARK: Overlay helpers

    /// Adds the newest microphone level to the wire and drops the oldest.
    private func push(level: Double) {
        levels.removeFirst()
        levels.append(level)
    }

    /// Shows a short message, then clears it.
    private func flash(_ message: String, seconds: Double = 2.5) {
        notice = message
        Toast.show(message, seconds: seconds)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, self.notice == message else { return }
            self.notice = nil
        }
    }
}

/// Files a transcribed link or file as a document. Whose words they are decides where they live: a
/// meeting is several people's, a voice note is the user's own, and what was transcribed from a link
/// or a file is someone else's, so it is a document like any other, with its times and its sound.
@MainActor
enum TranscribedDocument {
    /// Turns the recording an import saved into a document: the transcript is its text, the speakers are
    /// numbered (nobody in it is "Me"), and no notes are kept with it.
    static func file(_ id: Int64, link: String?, file: URL, in library: Library) {
        guard var item = try? library.item(id) else { return }
        var lines = (try? library.segments(itemID: id)) ?? []
        // The voices in the order they are first heard: "Speaker 1", "Speaker 2".
        var names: [String: String] = [:]
        for index in lines.indices {
            let was = lines[index].speaker
            if names[was] == nil { names[was] = "Speaker \(names.count + 1)" }
            lines[index].speaker = names[was] ?? was
        }
        try? library.replaceSegments(itemID: id, with: lines)
        item.kind = .document
        item.summary = ""
        item.rawText = ""
        // With several voices each line says whose it is; one voice is plain paragraphs.
        item.body = names.count > 1
            ? lines.map { "\($0.speaker): \($0.text)" }.joined(separator: "\n\n")
            : lines.map(\.text).joined(separator: "\n\n")
        if let link { item.source = link } else if item.source == nil { item.source = file.path }
        _ = try? library.save(item)
        try? library.save(DocumentExtra(itemID: id, format: format(link: link, file: file)))
        Log.write("speak", "a transcription was filed as a document: \(lines.count) lines, \(names.count) voices")
    }

    /// What the list calls it: the site for a link, "Podcast" for an episode's sound file, "Audio" or
    /// "Video" for a file from this Mac.
    static func format(link: String?, file: URL) -> String {
        if let link, let host = DocumentRows.host(link) {
            if host.hasSuffix("youtube.com") || host == "youtu.be" { return "YouTube" }
            let ending = (URL(string: link)?.pathExtension ?? "").lowercased()
            return ["mp4", "m4v", "mov"].contains(ending) || !MediaLink.soundEndings.contains(ending) ? "Video" : "Podcast"
        }
        return ["mp4", "m4v", "mov"].contains(file.pathExtension.lowercased()) ? "Video" : "Audio"
    }
}
