import AppKit
import ApplicationServices
import ChirpCore
import KeyboardShortcuts
import Observation
import SwiftUI

/// One stretch of underline drawn over another app. A problem that runs over a line break has one per line.
struct Underline: Identifiable, Equatable {
    /// The problem this underline is for.
    let issue: WritingIssue
    /// Screen rectangle of the flagged text, in Cocoa coordinates (origin bottom-left).
    let rect: CGRect
    /// Which line of the problem this is, counting from 0, so each piece has its own id.
    var piece = 0
    /// True for a word that is probably a name ("Garmin"): its line is fainter, because it is more
    /// likely to be right than wrong.
    var likelyName = false
    var id: String { "\(issue.id)#\(piece)" }
}

/// The small bird after a sentence that has something to fix. It has no words:
/// pointing at it shows the shortcut, and clicking it, or pressing the shortcut with the cursor in that
/// sentence, fixes the sentence.
struct SentenceBird: Equatable {
    /// The sentence and what it becomes.
    let fix: Proofreading.SentenceFix
    /// Where the bird is drawn, in Cocoa screen coordinates (origin bottom-left).
    let rect: CGRect
    /// The box of the sentence's last character: the line the bird belongs to, which its hint goes under.
    var line = CGRect.zero
}

extension KeyboardShortcuts.Name {
    /// Return, while a rewritten sentence is on its card waiting to be accepted. Registered only for
    /// as long as that card shows, so Return reaches the app in front at any other time.
    static let acceptRewrite = Self("acceptRewrite", default: .init(.return, modifiers: []))
}

/// Shows spelling and grammar underlines inside other apps' text fields.
///
/// A few times a second it looks at the focused text field of the frontmost app through Accessibility
/// (polling, because change notifications are unreliable in many apps), checks
/// the text with Harper, asks the app where each flagged range is on screen, and draws underlines in a
/// transparent window on top. Clicking an underline opens a card with the fix; the perch shows how many
/// there are and lists them. Apps that do not report usable positions get no underlines.
@MainActor
@Observable
final class UnderlineController {
    /// The user's switch for underlines in other apps. Kept between launches; turning it starts or stops the checking.
    var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "liveUnderlines")
            follow()
        }
    }

    /// Other apps' text is looked at only while underlines are switched on and Writing checks are.
    private func follow() {
        enabled && Features.on(.write) ? start() : stop()
    }
    /// True while other apps' text is being looked at.
    var isLooking: Bool { loop != nil }
    /// Why underlines are not showing right now, for the Options screen.
    private(set) var status = "" {
        didSet {
            guard status != oldValue else { return }
            Log.write("write", "underlines: \(status) (\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"))")
            if LinkHandler.debugEnabled {
                statusLog.append("\(Int(Date().timeIntervalSince1970 * 1000)) \(status)")
                if statusLog.count > 40 { statusLog.removeFirst() }
            }
        }
    }
    /// What is drawn right now, one entry per line of each problem on screen.
    private(set) var underlines: [Underline] = []
    /// The bird after each sentence on screen that has something to fix.
    private(set) var birds: [SentenceBird] = []
    /// The sentence whose bird the pointer is on, while its hint shows.
    private var hintFor: NSRange?
    /// The small window the bird's hint is shown in.
    private let hint = FloatingPanel()
    /// Rewrites one sentence with the language model and reads the answer by rule (set by the app).
    var rewriter: (@MainActor (WritingTask, String, WorkContext) async -> WritingAssistant.Checked?)?
    /// The note whose sentence is being rewritten, or has been: where the sentence is and how far it has got.
    private var note: (issue: WritingIssue, range: NSRange, sentence: String, task: WritingTask, state: SuggestionCard.NoteRewrite)?
    /// The rewrite running for that note.
    @ObservationIgnored private var noteWork: Task<Void, Never>?
    /// The underline the open card belongs to, so the card can be drawn again as its rewrite arrives.
    private var cardUnderline: Underline?
    /// The problems in the focused field, in order, for the perch's list. Empty when nothing can be shown.
    private(set) var shown: [WritingIssue] = []
    /// The text of the focused field, as last read.
    private(set) var text = ""
    /// The app being checked, by name.
    private(set) var appName = ""
    /// The bundle id of the app being checked, for its per-app setting.
    private var appID: String?
    /// True while the suggestions are being worked through from Chirp's bar with the keyboard: the text
    /// field has lost the keyboard for the moment, and what was found there is kept, not cleared.
    var reviewing = false
    /// When to measure again, for a field whose positions were not ready, and how often that has been tried.
    private var measureAgainAt: Date?
    private var measureTries = 0
    /// True while Fix all is putting its fixes in one after another; the usual checking waits.
    private var applying = false
    /// Problems that are not offered: inside code, or in a part of a web editor that is not on screen.
    private var unlisted: Set<WritingIssue.ID> = []
    /// Called when an app would not let Chirp put a fix in: the app's name, and the words the fix would
    /// have put there (the whole corrected text for Fix all), so they can be offered to copy.
    var onRefused: ((String, String?) -> Void)?
    /// Called when Fix all put some fixes in and could not place others: (fixed, left).
    var onPartly: ((Int, Int) -> Void)?
    /// Underlines are off everywhere until this time ("off for an hour").
    private(set) var pausedUntil: Date?
    /// The app in front has underlines turned off (its name), so the bar can say so and offer to turn them on.
    private(set) var offApp: String?
    /// Why there are no underlines although they could be shown, in a few words; nil when checks are running.
    var off: String? {
        if let until = pausedUntil, Date() < until {
            return "Suggestions are off until \(until.formatted(date: .omitted, time: .shortened))"
        }
        if let offApp { return "Suggestions are off in \(offApp)" }
        return nil
    }

    private let engine: PersonalLanguage
    private let checker: GrammarChecker
    /// The repeating look at the focused field. Nil while underlines are switched off.
    private var loop: Task<Void, Never>?
    private let overlay = UnderlineOverlay()
    /// The small window the suggestion card is shown in.
    private let card = FloatingPanel()

    // What is currently underlined.
    /// The text field being checked.
    private var element: AXUIElement?
    /// Everything found in the field, including problems that are not offered (see `unlisted`).
    private var issues: [WritingIssue] = []
    /// True while the text has changed since it was last checked.
    private var needsCheck = false
    /// When the text last changed. The check waits for a short pause in typing after this.
    private var lastChange = Date.distantPast
    /// Where the first problem was when last measured. If it is somewhere else now, the text has moved.
    private var anchor: CGRect?
    /// Where the field was when last measured, to notice a window being dragged or resized.
    private var fieldFrame: CGRect?
    /// The characters that were on screen when last looked at, to notice scrolling done without the wheel.
    private var lastVisible: NSRange?
    /// The id of the problem the pointer is resting on.
    private var hovered: String?
    /// The id of the problem whose card is open.
    private var cardIssue: String?
    /// A card opened by a click stays until it is used or dismissed; one opened by hovering leaves with the pointer.
    private var cardPinned = false
    /// Underlines are hidden while the text scrolls, and measured again once it settles.
    private var hiddenForScroll = false
    /// When scrolling counts as finished and the underlines can be measured again.
    private var settleAt = Date.distantPast
    /// Apps that have been seen in front, so each is asked to describe its text straight away the first time.
    private var preparedPIDs: Set<pid_t> = []
    /// When each app was last asked to describe its text. Cleared once a text field is found in it.
    private var askedAt: [pid_t: Date] = [:]
    /// The watchers for the pointer, scrolling and typing in other apps. Removed when underlines are switched off.
    private var monitors: [Any] = []
    /// The deeper check running for the field in the background. A newer check, or leaving the field, cancels it.
    @ObservationIgnored private var deepTask: Task<Void, Never>?
    /// The last answer to "are underlines on in this app?", kept for two seconds so the database is not asked
    /// on every look. A change made in the Library shows once it runs out; a change made here clears it.
    @ObservationIgnored private var enabledAnswer: (id: String, on: Bool, at: Date)?
    /// What the sentence shortcut was last worked out from. While none of it has changed, the offer stands.
    @ObservationIgnored private var sentenceOfferFor: (caret: Int, issues: [WritingIssue], text: String)?
    /// Where the cursor is in text seeded by `underline-seed` (no field behind it), for the bird's sentence.
    @ObservationIgnored private var seededCaret: Int?
    /// Apps that were slow to answer, which are left alone for a while so they cannot hold Chirp up.
    @ObservationIgnored private var slowApps = SlowAppGuard()
    /// How long to wait between looks: longer while nothing is changing.
    @ObservationIgnored private var backoff = PollBackoff()
    /// Set by anything that means the next look should come soon: an edit, a check waiting to run, a key or a click.
    @ObservationIgnored private var busy = true
    /// The wait before the next look. Cancelled to look at once.
    @ObservationIgnored private var nap: Task<Void, Never>?
    /// Tells when another app comes to the front. Removed when underlines are switched off.
    @ObservationIgnored private var frontWatch: NSObjectProtocol?
    /// The last field asked whether it belongs to a sign-in form, and the answer, so it is asked once and not on every look.
    @ObservationIgnored private var signInAnswer: (field: AXUIElement, yes: Bool)?
    /// For measuring (shown in the debug state): looks taken, the longest one, and when the status last changed.
    @ObservationIgnored private var looks = 0
    @ObservationIgnored private var longestLook = 0.0
    @ObservationIgnored private var lookTime = 0.0
    @ObservationIgnored private var statusLog: [String] = []

    init(engine: PersonalLanguage, checker: GrammarChecker) {
        self.engine = engine
        self.checker = checker
        enabled = UserDefaults.standard.object(forKey: "liveUnderlines") as? Bool ?? true
        follow()
        Features.shared.whenChanged { [weak self] old, new in
            guard let self, old.isOn(.write) != new.isOn(.write) else { return }
            if !new.isOn(.write) { self.reviewing = false }
            self.follow()
        }
        Features.shared.probe("write.lookingAtOtherApps") { [weak self] in self?.isLooking ?? false }
        Features.shared.probe("write.keyAndPointerWatchers") { [weak self] in self?.monitors.count ?? 0 }
        // The sentence birds on screen, the hint, the snippet cues offered, and how far a note's rewrite has got.
        LinkHandler.stateProviders["offers"] = { [weak self] in
            guard let self else { return [:] }
            var out: [String: Any] = [:]
            out["birds"] = self.birds.map { [$0.rect.minX, $0.rect.minY, $0.rect.width, $0.rect.height] }
            out["hint"] = self.hintFor != nil
            out["snippets"] = self.shown.filter { $0.category == .snippet }.map { $0.flagged(in: self.text) }
            out["rules"] = self.shown.map(\.rule)
            out["buttons"] = self.shown.map { Proofreading.sentenceRewrite(for: $0)?.title ?? "" }
            switch self.note?.state {
            case .working: out["note"] = "working"
            case .ready(let new, let summary):
                out["note"] = "ready"
                out["noteText"] = new
                out["noteSummary"] = summary
            case .failed(let why):
                out["note"] = "failed"
                out["noteText"] = why
            case nil: out["note"] = ""
            }
            let fixes = Proofreading.sentenceFixes(in: self.text, issues: self.shown)
            out["sentences"] = fixes.map { (self.text as NSString).substring(with: $0.range) }
            out["becomes"] = fixes.map(\.replacement)
            // The one sentence with a bird: in a real field the one drawn; for seeded text the one at
            // the seeded cursor (`underline-seed?caret=`, the end of the text when not given).
            let ns = self.text as NSString
            let birdFix = self.element != nil ? self.birds.first?.fix : SentenceBirdRule.sentence(in: self.text, caret: self.seededCaret, issues: self.shown)
            out["birdSentence"] = birdFix.flatMap { NSMaxRange($0.range) <= ns.length ? ns.substring(with: $0.range) : nil } ?? ""
            return out
        }
        LinkHandler.stateProviders["underlines"] = { [weak self] in
            guard let self else { return [:] }
            return [
                "enabled": self.enabled, "status": self.status, "count": self.shown.count,
                "words": self.shown.map { $0.flagged(in: self.text) },
                "rects": self.underlines.map { [$0.rect.minX, $0.rect.minY, $0.rect.width, $0.rect.height] },
                "fieldText": self.text, "card": self.cardIssue != nil,
                // The words whose line is fainter because they are probably names, and what the open card leads with.
                "likelyNames": self.shown.filter { Proofreading.likelyName($0, in: self.text) }.map { $0.flagged(in: self.text) },
                "faintLines": self.underlines.filter(\.likelyName).count,
                "looks": self.looks, "longestLookMs": Int(self.longestLook * 1000), "lookTimeMs": Int(self.lookTime * 1000), "stride": self.backoff.stride,
                "statusLog": self.statusLog, "applying": self.applying,
            ]
        }
        // For measuring: Fix all, as the button on the perch does it; and forgetting the counts above.
        LinkHandler.commands["underline-fixall"] = { [weak self] q in
            guard let self, q["app"] == self.appID else { return }
            self.fixAll()
        }
        LinkHandler.commands["underline-reset"] = { [weak self] _ in
            self?.looks = 0
            self?.longestLook = 0
            self?.lookTime = 0
            self?.statusLog = []
        }
        // Apply the first suggestion of problem number `index`, as clicking it in the card would.
        LinkHandler.commands["underline-apply"] = { [weak self] q in
            guard let self, let issue = self.shown[safe: Int(q["index"] ?? "0") ?? 0], let fix = issue.suggestions.first else { return }
            self.apply(fix, to: issue)
        }
        // For test links: lists what the checker finds in some text as if it were in a field in front, so
        // the perch's list of suggestions can be looked at without another app. Nothing is drawn or changed.
        // `underline-seed` with no text lets go again: without it the seeded list stayed, and the real
        // text in front was not checked until a keyboard review had been opened and closed.
        LinkHandler.commands["underline-seed"] = { [weak self] q in
            guard let self else { return }
            guard let seeded = q["text"], !seeded.isEmpty else {
                self.reviewing = false
                self.needsCheck = true
                return
            }
            self.reviewing = true
            self.text = seeded
            self.seededCaret = q["caret"].flatMap(Int.init) ?? (seeded as NSString).length
            self.appName = q["app"] ?? "Mail"
            self.shown = self.checker.checkNow(self.text)
        }
        // The card and the two kinds of line, drawn to a picture without another app: `card-shot?text=…&index=0&path=…`
        // writes the card for the nth problem found in the text, with a normal and a likely-name line above it
        // (`dark=1` for the dark look).
        LinkHandler.commands["card-shot"] = { [weak self] q in
            guard let self, let text = q["text"], let path = q["path"] else { return }
            let issues = self.checker.checkNow(text)
            guard let issue = issues[safe: Int(q["index"] ?? "0") ?? 0] else { return }
            let lines = UnderlineOverlayModel()
            lines.height = 16
            lines.underlines = [
                Underline(issue: issue, rect: CGRect(x: 10, y: 8, width: 70, height: 12), piece: 0, likelyName: false),
                Underline(issue: issue, rect: CGRect(x: 100, y: 8, width: 70, height: 12), piece: 1, likelyName: true),
            ]
            // `rewrite=working`, or `rewrite=<the new sentence>` for the change to accept, or `failed=<why>`.
            var state: SuggestionCard.NoteRewrite?
            if q["rewrite"] == "working" {
                state = .working
            } else if let new = q["rewrite"], let offer = Proofreading.sentenceRewrite(for: issue) {
                let old = Proofreading.sentenceRange(in: text, at: min(issue.start + 1, issue.end)).map { (text as NSString).substring(with: $0) } ?? text
                state = .ready(new, Proofreading.rewriteSummary(task: offer.task, from: old, to: new))
            } else if let why = q["failed"] {
                state = .failed(why)
            }
            let view = VStack(alignment: .leading, spacing: 8) {
                UnderlineOverlayView(model: lines).frame(width: 180, height: 16)
                SuggestionCard(issue: issue, text: text, rewrite: state) { _ in }
            }
            .padding(12).background(Color.paper)
            .environment(\.colorScheme, q["dark"] == "1" ? .dark : .light)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            if let image = renderer.cgImage {
                try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
        }
        // The sentence bird and its hint, drawn to a picture without another app: `bird-shot?text=…&path=…`
        // lays the text out in a box as a text field would, with the lines under its problems and the bird
        // after each sentence that has a fix (`hint=1` adds the hint under the first; `dark=1`; `caret=N` puts the
        // cursor there; `top=N` leaves N points above the first line inside the field; `size=N` the text size).
        LinkHandler.commands["bird-shot"] = { [weak self] q in
            guard let self, let text = q["text"], let path = q["path"] else { return }
            SentenceBirdShot.write(
                text: text, issues: self.checker.checkNow(text), hint: q["hint"] == "1", dark: q["dark"] == "1",
                caret: q["caret"].flatMap { Int($0) }, topRoom: q["top"].flatMap { Double($0) }.map { CGFloat($0) } ?? 0,
                size: q["size"].flatMap { Double($0) }.map { CGFloat($0) } ?? 15, to: path)
        }
        // Clicks the bird of sentence number `index` (as seeded with `underline-seed`), applying it to the seeded text.
        LinkHandler.commands["bird-click"] = { [weak self] q in
            guard let self, let fix = Proofreading.sentenceFixes(in: self.text, issues: self.shown)[safe: Int(q["index"] ?? "0") ?? 0] else { return }
            if self.element != nil { return self.fixSentence(fix) }
            // Seeded text has no field behind it: the text itself is changed, and checked again.
            self.text = (self.text as NSString).replacingCharacters(in: fix.range, with: fix.replacement)
            self.shown = self.checker.checkNow(self.text)
        }
        // A note's one button, on seeded text: `note-rewrite?index=0` runs the language model on that note's
        // sentence; `note-accept` puts the change in. `state` has `underlines.note`.
        LinkHandler.commands["note-rewrite"] = { [weak self] q in
            guard let self, let issue = self.shown[safe: Int(q["index"] ?? "0") ?? 0] else { return }
            self.startNoteRewrite(issue)
        }
        LinkHandler.commands["note-accept"] = { [weak self] _ in self?.acceptNoteRewrite() }
        KeyboardShortcuts.onKeyDown(for: .acceptRewrite) { [weak self] in self?.acceptNoteRewrite() }
        KeyboardShortcuts.disable(.acceptRewrite)
        LinkHandler.commands["underline-card"] = { [weak self] q in
            guard let self, let issue = self.shown[safe: Int(q["index"] ?? "0") ?? 0],
                let u = self.underlines.first(where: { $0.issue.id == issue.id })
            else { return }
            self.showCard(for: u, pinned: true)
        }
    }

    /// Starts the repeating check and the watchers for the pointer, scrolling and typing.
    private func start() {
        // A test copy run beside the real Chirp leaves other apps' text alone.
        guard !LinkHandler.noGlobalShortcuts else { return }
        // An app that has stopped answering must not hold Chirp up. Set on
        // the system-wide element, the limit covers every Accessibility request Chirp makes; set on one app's
        // element it would cover only that one object.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 1.0)
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let began = Date()
                self.busy = false
                await self.tick()
                let took = Date().timeIntervalSince(began)
                self.looks += 1
                self.longestLook = max(self.longestLook, took)
                self.lookTime += took
                // Work still to come (a check waiting for a pause in typing, underlines to put back after
                // a scroll, a web editor not ready yet) keeps the looks coming at full speed.
                let pending = self.needsCheck || self.hiddenForScroll || self.measureAgainAt != nil || self.applying || self.reviewing
                self.backoff.record(changed: self.busy || pending)
                // The wait can be cut short (`lookSoon`), so a key or a click is answered at once
                // however long the gap had grown.
                let gap = 150 * self.backoff.stride
                let nap = Task<Void, Never> { _ = try? await Task.sleep(for: .milliseconds(gap)) }
                self.nap = nap
                await nap.value
            }
        }
        guard monitors.isEmpty else { return }
        frontWatch = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.lookSoon() } }
        let add: (NSEvent.EventTypeMask, @escaping @MainActor (NSEvent) -> Void) -> Void = { [weak self] mask, handler in
            if let monitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { event in Task { @MainActor in handler(event) } }) {
                self?.monitors.append(monitor)
            }
        }
        add([.mouseMoved, .leftMouseDown]) { [weak self] event in
            // A click can move the keyboard to another field; moving the pointer changes nothing in the text.
            if event.type == .leftMouseDown { self?.lookSoon() }
            self?.pointerMoved(clicked: event.type == .leftMouseDown)
        }
        // Scrolling moves the text out from under the underlines: hide them until it stops.
        add(.scrollWheel) { [weak self] _ in
            self?.lookSoon()
            self?.scrolled()
        }
        // Typing, or Escape, puts the card away.
        add(.keyDown) { [weak self] _ in
            self?.lookSoon()
            // A card about to open for the word under the pointer is called off too: the text is changing.
            self?.hovered = nil
            self?.hideCard()
        }
    }

    /// Stops checking and takes everything off the screen.
    private func stop() {
        loop?.cancel()
        loop = nil
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors = []
        if let frontWatch { NSWorkspace.shared.notificationCenter.removeObserver(frontWatch) }
        frontWatch = nil
        nap?.cancel()
        clear(status: "Off")
    }

    /// The user did something (a key, a click, a scroll, another app in front): the next look comes at
    /// once and the looks go back to full speed.
    private func lookSoon() {
        busy = true
        guard backoff.stride > 1 else { return }
        backoff.reset()
        nap?.cancel()
    }

    /// Forgets the field and removes the underlines, the card and the sentence shortcut. `status` says why.
    private func clear(status: String) {
        self.status = status
        deepTask?.cancel()
        deepTask = nil
        // This runs on every look while there is nothing to check. Once everything is put away there is no more to do.
        guard element != nil || !underlines.isEmpty || !shown.isEmpty || !issues.isEmpty || !text.isEmpty || cardIssue != nil else { return }
        sentenceOfferFor = nil
        if !underlines.isEmpty { underlines = [] }
        if !birds.isEmpty { birds = [] }
        hideHint()
        if !shown.isEmpty { shown = [] }
        overlay.show([])
        element = nil
        if !text.isEmpty { text = "" }
        issues = []
        needsCheck = false
        anchor = nil
        fieldFrame = nil
        hideCard()
        SentenceFixer.shared.withdraw(owner: "other")
    }

    /// If the sentence at the cursor has fixes, the shortcut that applies them all is switched on.
    private func offerSentenceFix(in element: AXUIElement) {
        guard !needsCheck, let range = TextInserter.rangeValue(element, kAXSelectedTextRangeAttribute), range.length == 0 else {
            sentenceOfferFor = nil
            // The bird goes with the offer.
            if !birds.isEmpty { placeBird(in: element) }
            return SentenceFixer.shared.withdraw(owner: "other")
        }
        // Same text, same problems, same cursor as the last look: the offer (or the lack of one) stands.
        if let last = sentenceOfferFor, last.caret == range.location, last.issues == issues, last.text == text { return }
        sentenceOfferFor = (range.location, issues, text)
        // The cursor moved, or the text or its problems changed: the one bird follows the sentence at the cursor.
        placeBird(in: element)
        guard let fix = Proofreading.sentenceFix(in: text, caret: range.location, issues: issues) else {
            return SentenceFixer.shared.withdraw(owner: "other")
        }
        let before = text
        SentenceFixer.shared.offer(fix, owner: "other") { [weak self] in
            guard let self else { return }
            // Pressing the shortcut takes the offer back; if nothing ends up changed, the next look makes it again.
            self.sentenceOfferFor = nil
            guard self.text == before else { return }
            self.rewrite(to: (before as NSString).replacingCharacters(in: fix.range, with: fix.replacement))
        }
    }

    // MARK: The loop

    /// One look at the focused field: works out whether it may be checked, notices a new field, an edit, a scroll
    /// or a move, and then checks or measures again as needed.
    private func tick() async {
        guard AXIsProcessTrusted() else { return clear(status: "Needs Accessibility permission") }
        guard !reviewing, !applying else { return }
        if let until = pausedUntil {
            if Date() < until { return clear(status: "Off for now") }
            pausedUntil = nil
        }
        guard let front = NSWorkspace.shared.frontmostApplication, front.bundleIdentifier != Bundle.main.bundleIdentifier else {
            return clear(status: "Chirp checks its own editor directly")
        }
        let context = WorkContext(bundleID: front.bundleIdentifier, appName: front.localizedName)
        appID = front.bundleIdentifier
        if appName != (front.localizedName ?? "") { appName = front.localizedName ?? "" }
        guard underlinesOn(for: context) else {
            if offApp != front.localizedName { offApp = front.localizedName ?? "this app" }
            return clear(status: "Off for \(front.localizedName ?? "this app")")
        }
        if offApp != nil { offApp = nil }
        // An app that was slow to answer a moment ago is not asked again yet: each question would hold
        // Chirp up for the full time limit.
        let pid = front.processIdentifier
        if slowApps.resting(pid) {
            return clear(status: "\(front.localizedName ?? "This app") is not answering")
        }
        prepare(pid)
        let asked = Date()
        let found = TextInserter.focusedElement()
        let field = found.flatMap { Self.isEditableText($0) ? $0 : nil }
        let read = field.flatMap { TextInserter.text(of: $0) }
        // A slow answer is still used; only slow answers in a row, or one that hangs, rest the app.
        if let rest = slowApps.record(pid, took: Date().timeIntervalSince(asked)) {
            Log.write("write", "underlines: \(front.bundleIdentifier ?? "?") took \(String(format: "%.1f", Date().timeIntervalSince(asked))) s to answer; leaving it alone for \(Int(rest)) s")
            return clear(status: "\(front.localizedName ?? "This app") is not answering")
        }
        guard let focused = field, let value = read, !value.isEmpty else { return clear(status: "No text field in focus") }
        guard value.utf16.count < 120_000 else { return clear(status: "This text is too long to check as you type") }
        // The boxes of a sign-in or payment form (e-mail, user name, one-time code, card number) are not
        // writing, and are not read further.
        guard !isSignIn(focused, text: value) else { return clear(status: "Sign-in fields are left alone") }
        askedAt[pid] = nil  // it answers; no need to keep asking

        if element == nil || !CFEqual(element, focused) {
            // A different field: start again.
            element = focused
            text = value
            issues = []
            needsCheck = true
            lastChange = Date()
            busy = true
            hideCard()
            layout(in: focused)
            return
        }
        if value != text {
            busy = true
            // The same field, edited. The underlines that the edit did not touch stay under their words;
            // the check runs again once typing pauses.
            issues = Proofreading.carry(issues, from: text, to: value)
            text = value
            needsCheck = true
            lastChange = Date()
            if let open = cardIssue, !issues.contains(where: { $0.id == open }) { hideCard() }
            layout(in: focused)
            return
        }

        if needsCheck {
            guard Date().timeIntervalSince(lastChange) > 0.25 else { return }
            let found = await checker.check(value)
            // The field may have changed while checking.
            guard value == text else { return }
            // Text quoted from someone else (the message being replied to) is not the user's to correct.
            let quoted = TextInserter.usesTextMarkers(focused) ? Self.quotedRanges(in: focused, text: value) : []
            issues = quoted.isEmpty ? found : found.filter { issue in !quoted.contains { NSIntersectionRange($0, issue.range).length > 0 } }
            needsCheck = false
            layout(in: focused)
            if GrammarChecker.deepEnabled, GrammarChecker.deepInOtherApps {
                // Look deeper in the background; if that finds more, check this text again to show it.
                // What it learns is kept paragraph by paragraph, so it is worth a fresh check even if other
                // text has changed since. Only one runs at a time: a newer check replaces it.
                deepTask?.cancel()
                deepTask = Task { [weak self] in
                    guard let self, await self.checker.deepen(value), self.element != nil else { return }
                    self.needsCheck = true
                }
            }
        } else if hiddenForScroll {
            guard Date() >= settleAt else { return }
            hiddenForScroll = false
            layout(in: focused)
        } else if moved(focused) {
            // Same text, but it moved (a window drag or resize): measure again.
            busy = true
            layout(in: focused)
        } else if let at = measureAgainAt, Date() >= at {
            // A web editor that has only just been asked to describe itself has no text pieces yet.
            // It is measured again each second until it does, instead of waiting for the next edit.
            measureAgainAt = nil
            layout(in: focused)
        }
        offerSentenceFix(in: focused)
    }

    /// Whether underlines are on in the app in front, asking the database at most every two seconds.
    private func underlinesOn(for context: WorkContext) -> Bool {
        let id = context.bundleID ?? ""
        if let known = enabledAnswer, known.id == id, Date().timeIntervalSince(known.at) < 2 { return known.on }
        let on = (try? engine.underlinesEnabled(for: context)) ?? true
        enabledAnswer = (id, on, Date())
        return on
    }

    /// Whether the field or its first problem is somewhere other than where it was last measured.
    private func moved(_ element: AXUIElement) -> Bool {
        if Self.frame(of: element) != fieldFrame { return true }
        // The keyboard and the scroll bar move the text too, without a scroll-wheel event.
        let visible = Self.visibleRange(in: element)
        if visible != lastVisible {
            lastVisible = visible
            return true
        }
        guard let first = issues.first else { return false }
        return Self.bounds(of: first.range, in: element) != anchor
    }

    /// The wheel moved: hide the underlines, and measure again shortly after the last movement.
    private func scrolled() {
        guard !underlines.isEmpty || hiddenForScroll else { return }
        if !hiddenForScroll {
            hiddenForScroll = true
            overlay.show([])
            underlines = []
            birds = []
            hideHint()
            hideCard()
        }
        settleAt = Date().addingTimeInterval(0.2)
    }

    /// Asks the app where each visible issue is and draws the underlines.
    private func layout(in element: AXUIElement) {
        var result: [Underline] = []
        var placed = 0
        var invalid = 0
        // Accessibility measures from the top of the main screen; windows are placed from its bottom.
        let screenHeight = NSScreen.screens.first?.frame.height ?? 0
        fieldFrame = Self.frame(of: element)
        // Only what is on screen is measured: a long document has most of its text scrolled out of sight,
        // and the app still reports positions for it, above and below the window.
        let visible = Self.visibleRange(in: element)
        let window = Self.visibleFrame(of: element) ?? fieldFrame
        var measured = 0
        var runs: [TextRun]?
        var left: Set<WritingIssue.ID> = []
        let began = Date()
        for issue in issues {
            if let visible, NSIntersectionRange(visible, issue.range).length == 0 { continue }
            guard measured < 120 else { break }
            // An app that stops answering part of the way through is not asked about the rest.
            if Date().timeIntervalSince(began) > 1.5 {
                var pid: pid_t = 0
                // Slow but answering: what is measured so far is shown; only a rest clears it.
                if AXUIElementGetPid(element, &pid) == .success, slowApps.record(pid, took: Date().timeIntervalSince(began)) != nil {
                    return clear(status: "\(appName.isEmpty ? "This app" : appName) is not answering")
                }
                break
            }
            measured += 1
            var pieces = Self.lineBounds(of: issue.range, in: element)
            // Chromium and Electron editors (Obsidian, Slack) answer with an empty rectangle for the field
            // itself. The pieces of text inside it do know where they are, so they are asked instead.
            if pieces.isEmpty || pieces.contains(where: { $0.width <= 1 || $0.height <= 1 }) {
                if runs == nil { runs = Self.textRuns(in: element, text: text) }
                if let runs, !runs.isEmpty {
                    // Code is not prose: a problem "found" in a code block or inline code is dropped.
                    if runs.contains(where: { $0.code && NSIntersectionRange($0.range, issue.range).length > 0 }) {
                        left.insert(issue.id)
                        continue
                    }
                    pieces = Self.runBounds(of: issue.range, in: runs)
                    // Such editors only keep the lines on screen. A problem further off has nothing to ask,
                    // and could be inside code, so it is left out until it scrolls into view.
                    if pieces.isEmpty {
                        left.insert(issue.id)
                        continue
                    }
                }
            }
            guard !pieces.isEmpty else {
                invalid += 1
                continue
            }
            // Zero-size, origin or impossible rectangles mean the app does not really know where the text is.
            let usable = pieces.filter { r in
                r.width > 1 && r.height > 1 && !(r.origin.x == 0 && r.origin.y == 0)
                    && r.origin.x.isFinite && r.origin.y.isFinite && r.width < 4000 && r.height < 400
            }
            guard usable.count == pieces.count else {
                invalid += 1
                continue
            }
            // A line cut off by the edge of the scrolling area is not drawn under.
            let inside = usable.filter { r in window.map { $0.insetBy(dx: -2, dy: -2).contains(r) } ?? true }
            guard !inside.isEmpty else { continue }
            placed += 1
            for (n, r) in inside.enumerated() {
                result.append(Underline(
                    issue: issue, rect: CGRect(x: r.minX, y: screenHeight - r.maxY, width: r.width, height: r.height), piece: n,
                    likelyName: Proofreading.likelyName(issue, in: text)))
            }
        }
        anchor = issues.first.flatMap { Self.bounds(of: $0.range, in: element) }
        var listed = issues.filter { !left.contains($0.id) }
        unlisted = left
        // One bird, for the sentence the cursor is in or has just finished, while it has a fix.
        var marks: [SentenceBird] = []
        if invalid <= placed, !result.isEmpty {
            marks = birdMarks(in: element, listed: listed, visible: visible, window: window, runs: &runs)
        }
        if birds != marks { birds = marks }
        if let open = hintFor, !marks.contains(where: { $0.fix.range == open }) { hideHint() }
        if invalid > placed {
            // Mostly unusable positions: better no underlines than misplaced ones.
            result = []
            listed = []
            status = "This app does not report where its text is. Use the shortcut panel here."
            if measureTries < 30 {
                measureTries += 1
                measureAgainAt = Date().addingTimeInterval(1)
            }
        } else if !needsCheck {
            measureTries = 0
            status = listed.isEmpty ? "Nothing to fix" : "\(listed.count) found, \(placed) on screen"
        }
        if underlines != result { underlines = result }
        if shown != listed { shown = listed }
        overlay.show(result, birds: result.isEmpty ? [] : marks)
    }

    /// The bird for the sentence at the cursor: the sentence the cursor is in or has just finished,
    /// only while it has a fix, the same one ⌥⇥ fixes. Its place is taken from the box of the sentence's
    /// last character, asked for as that one character: a range of no length, or the whole sentence's box,
    /// gives the wrong line in some apps. It goes after that character when there is room before the next word or the edge, else a
    /// small bird just above it when nothing is there, else nowhere: it never covers text and never goes
    /// to the end of the line (`SentenceBirdRule`).
    private func birdMarks(in element: AXUIElement, listed: [WritingIssue], visible: NSRange?, window: CGRect?, runs: inout [TextRun]?) -> [SentenceBird] {
        let ns = text as NSString
        let length = ns.length
        let caret = TextInserter.rangeValue(element, kAXSelectedTextRangeAttribute).flatMap { $0.length == 0 ? $0.location : nil }
        guard !needsCheck, let fix = SentenceBirdRule.sentence(in: text, caret: caret, issues: listed) else { return [] }
        // The sentence's last character that is not a space: the bird belongs over or after it.
        var lastAt = NSMaxRange(fix.range) - 1
        while lastAt > fix.range.location, lastAt < length, [32, 9, 10, 13].contains(ns.character(at: lastAt)) { lastAt -= 1 }
        let last = NSRange(location: lastAt, length: 1)
        guard last.location >= 0, NSMaxRange(last) <= length else { return [] }
        if let visible, NSIntersectionRange(visible, last).length == 0 { return [] }
        func box(_ range: NSRange) -> CGRect? {
            var pieces = Self.lineBounds(of: range, in: element)
            if pieces.isEmpty || pieces.contains(where: { $0.width <= 1 || $0.height <= 1 }) {
                if runs == nil { runs = Self.textRuns(in: element, text: text) }
                if let runs, !runs.isEmpty { pieces = Self.runBounds(of: range, in: runs) }
            }
            guard let r = pieces.last, r.width > 0.5, r.height > 1, r.height < 400, r.origin.x.isFinite, r.origin.y.isFinite,
                !(r.origin.x == 0 && r.origin.y == 0)
            else { return nil }
            return r
        }
        guard let end = box(last) else { return [] }
        if let window, !window.insetBy(dx: -2, dy: -2).contains(end) { return [] }
        var next = NSMaxRange(fix.range)
        while next < length, [32, 9].contains(ns.character(at: next)) { next += 1 }
        let following = next < length && ![10, 13].contains(ns.character(at: next)) ? box(NSRange(location: next, length: 1)) : nil
        // The line above the last character, from the app's own lines (a text view says; a web editor does
        // not, and then there is no bird above): a small bird can sit there only where nothing is.
        var textAbove: [CGRect]?
        if let n = Self.line(of: last.location, in: element) {
            if n == 0 {
                textAbove = []
            } else if let line = Self.range(ofLine: n - 1, in: element), line.length > 0 {
                let pieces = Self.lineBounds(of: line, in: element).filter { $0.width > 0.5 && $0.height > 1 }
                if !pieces.isEmpty { textAbove = pieces }
            }
        }
        guard let place = SentenceBirdRule.place(end: end, next: following, right: window?.maxX, top: window?.minY, textAbove: textAbove) else { return [] }
        let screenHeight = NSScreen.screens.first?.frame.height ?? 0
        return [SentenceBird(
            fix: fix, rect: CGRect(x: place.minX, y: screenHeight - place.maxY, width: place.width, height: place.height),
            line: CGRect(x: end.minX, y: screenHeight - end.maxY, width: end.width, height: end.height))]
    }

    /// The cursor moved to or from a sentence with a fix: the bird follows it without measuring every underline again.
    private func placeBird(in element: AXUIElement) {
        guard !underlines.isEmpty else {
            if !birds.isEmpty { birds = [] }
            return
        }
        var runs: [TextRun]?
        let marks = birdMarks(in: element, listed: shown, visible: Self.visibleRange(in: element), window: Self.visibleFrame(of: element) ?? fieldFrame, runs: &runs)
        guard marks != birds else { return }
        birds = marks
        if let open = hintFor, !marks.contains(where: { $0.fix.range == open }) { hideHint() }
        overlay.show(underlines, birds: marks)
    }

    // MARK: Pointing at an underline

    /// Opens the card for the underline under the pointer (at once on a click, after a moment when resting
    /// there) and closes a card the pointer has left.
    private func pointerMoved(clicked: Bool) {
        let p = NSEvent.mouseLocation
        // The bird first: pointing at it shows the shortcut, clicking it fixes its sentence. The hit area is
        // a little larger than the bird, so it is easy to hit.
        if let bird = birds.first(where: { $0.rect.insetBy(dx: -3, dy: -3).contains(p) }) {
            if clicked {
                hideHint()
                return fixSentence(bird.fix)
            }
            return showHint(for: bird)
        }
        hideHint()
        let onCard = card.frame.map { $0.insetBy(dx: -14, dy: -14).contains(p) } ?? false
        guard let hit = underlines.first(where: { $0.rect.insetBy(dx: -2, dy: -4).contains(p) }) else {
            hovered = nil
            // A click somewhere else, or (for a card that opened on its own) moving away, puts the card away.
            if cardIssue != nil, !onCard, clicked || !cardPinned { hideCard() }
            return
        }
        if clicked {
            // Clicking the word opens its card and keeps it open.
            hovered = hit.issue.id
            return showCard(for: hit, pinned: true)
        }
        guard hovered != hit.issue.id else { return }
        hovered = hit.issue.id
        // Resting on a word opens its card too, after a moment, so passing over text does not flash cards.
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            // The text may have changed while waiting. The card opens only if this very problem is still
            // underlined; one that has moved has a new place, and the old one would point at the wrong letters.
            guard let self, self.hovered == hit.issue.id, self.cardIssue != hit.issue.id,
                let current = self.underlines.first(where: { $0.issue == hit.issue })
            else { return }
            self.showCard(for: current, pinned: false)
        }
    }

    /// Puts the suggestion card away, if one is open, and drops a rewrite that was on it.
    private func hideCard() {
        if note != nil {
            noteWork?.cancel()
            noteWork = nil
            note = nil
            KeyboardShortcuts.disable(.acceptRewrite)
        }
        guard cardIssue != nil else { return }
        card.hide()
        cardIssue = nil
        cardPinned = false
        cardUnderline = nil
    }

    /// Shows "Fix this sentence ⌥⇥" under a bird the pointer is on.
    private func showHint(for bird: SentenceBird) {
        guard hintFor != bird.fix.range else { return }
        hintFor = bird.fix.range
        let view = SentenceHint(keys: KeyboardShortcuts.getShortcut(for: .fixSentence)?.description ?? "")
        let size = NSHostingView(rootView: view).fittingSize
        let under = bird.line.isEmpty ? bird.rect : bird.line
        hint.show(view, size: size, at: NSPoint(x: bird.rect.minX - 10, y: under.minY - size.height - 6))
    }

    private func hideHint() {
        guard hintFor != nil else { return }
        hintFor = nil
        hint.hide()
    }

    /// Fixes one sentence: what a click on its bird does. (The shortcut does the same for the sentence the
    /// cursor is in, through `SentenceFixer`.)
    private func fixSentence(_ fix: Proofreading.SentenceFix) {
        lookSoon()
        guard element != nil, NSMaxRange(fix.range) <= (text as NSString).length else { return }
        Log.write("write", "fix sentence: \(fix.count) fixes (bird)")
        FixTally.add(fix.count)
        sentenceOfferFor = nil
        rewrite(to: (text as NSString).replacingCharacters(in: fix.range, with: fix.replacement))
    }

    // MARK: A note's one button

    /// Rewrites the sentence a note is about with the language model, and shows the change on the card.
    private func startNoteRewrite(_ issue: WritingIssue) {
        guard let offer = Proofreading.sentenceRewrite(for: issue), let rewriter, note?.state != .working else { return }
        var range = Proofreading.sentenceRange(in: text, at: min(issue.start + 1, issue.end)) ?? issue.range
        if issue.range.length > range.length { range = issue.range }
        guard NSMaxRange(range) <= (text as NSString).length else { return }
        let sentence = (text as NSString).substring(with: range)
        note = (issue, range, sentence, offer.task, .working)
        cardPinned = true
        redrawCard()
        let context = WorkContext(bundleID: appID, appName: appName)
        Log.write("write", "note: \(offer.title) (\(sentence.count) characters)")
        noteWork?.cancel()
        noteWork = Task { [weak self] in
            let checked = await rewriter(offer.task, sentence, context)
            guard let self, !Task.isCancelled, var current = self.note, current.issue == issue else { return }
            if let new = checked?.text {
                current.state = .ready(new, Proofreading.rewriteSummary(task: offer.task, from: sentence, to: new))
                // Return accepts it while the card shows; the key is given back the moment the card goes.
                KeyboardShortcuts.enable(.acceptRewrite)
            } else {
                current.state = .failed(RewriteCheck.message(task: offer.task, problems: checked?.problems ?? [.empty]))
            }
            self.note = current
            self.redrawCard()
        }
    }

    /// Puts the rewritten sentence where the old one was, if the text has not moved on.
    private func acceptNoteRewrite() {
        guard let current = note, case .ready(let new, _) = current.state else { return }
        let ns = text as NSString
        guard NSMaxRange(current.range) <= ns.length, ns.substring(with: current.range) == current.sentence else {
            hideCard()
            needsCheck = true
            return Log.write("write", "note: the text changed under a rewrite, so it was not put in")
        }
        hideCard()
        lookSoon()
        Log.write("write", "note: replaced a sentence (\(current.issue.rule))")
        FixTally.add()
        let updated = ns.replacingCharacters(in: current.range, with: new)
        if element == nil {
            // Seeded text (a test link) has no field behind it.
            text = updated
            shown = checker.checkNow(updated)
            return
        }
        rewrite(to: updated, dropping: current.issue)
    }

    /// Draws the open card again where it is, after its rewrite has moved on.
    private func redrawCard() {
        guard let underline = cardUnderline ?? underlines.first(where: { $0.issue.id == note?.issue.id }) else { return }
        showCard(for: underline, pinned: true)
    }

    /// Opens the suggestion card beside a problem. `pinned` keeps it open when the pointer moves away.
    private func showCard(for underline: Underline, pinned: Bool) {
        // Another problem's card takes the place of one with a rewrite on it.
        if let current = note, current.issue.id != underline.issue.id { hideCard() }
        cardIssue = underline.issue.id
        cardPinned = pinned
        cardUnderline = underline
        let state = note?.issue.id == underline.issue.id ? note?.state : nil
        let view = SuggestionCard(issue: underline.issue, text: text, rewrite: state) { [weak self] action in self?.perform(action, on: underline.issue) }
        let size = NSHostingView(rootView: view).fittingSize
        // Under the line the word is on, or over it when there is no room below.
        let lines = underlines.filter { $0.issue.id == underline.issue.id }.map(\.rect)
        let bottom = lines.map(\.minY).min() ?? underline.rect.minY
        let top = lines.map(\.maxY).max() ?? underline.rect.maxY
        let screen = NSScreen.screens.first { $0.frame.contains(underline.rect.origin) }?.visibleFrame ?? .zero
        let below = bottom - size.height - 6
        card.show(view, size: size, at: NSPoint(x: underline.rect.minX - 10, y: below >= screen.minY + 4 ? below : top + 6))
    }

    // MARK: Acting on a problem

    /// Puts a fix into the other app's text. Used by the perch's list as well as the card.
    func apply(_ fix: Fix, to issue: WritingIssue) { perform(.apply(fix), on: issue) }
    /// Hides this suggestion for this exact text from now on.
    func dismiss(_ issue: WritingIssue) { perform(.dismiss, on: issue) }

    /// Carries out what was chosen on a card or in the perch's list: apply a fix, dismiss, stop the rule, or
    /// add the word to the dictionary.
    private func perform(_ action: IssueAction, on issue: WritingIssue) {
        // A note's rewrite keeps its card open while it works, and then to show the change.
        if case .rewrite = action { return startNoteRewrite(issue) }
        if case .acceptRewrite = action { return acceptNoteRewrite() }
        hideCard()
        // A click on Chirp's own card or list is not seen by the watchers on other apps.
        lookSoon()
        switch action {
        case .apply(let fix):
            guard let element else {
                return Log.write("write", "underlines: could not apply a fix, the text field was no longer in focus")
            }
            // A card or a row in the list made before the text last changed points at the wrong place.
            guard issues.contains(issue) else {
                needsCheck = true
                return Log.write("write", "underlines: a fix was for text that has since changed, so it was not applied")
            }
            // The text may have moved on since the check: find the problem where it is now.
            let live = TextInserter.text(of: element) ?? text
            guard let current = live == text ? issue : Proofreading.carry([issue], from: text, to: live).first else {
                needsCheck = true
                return Log.write("write", "underlines: the text changed under a fix, so it was not applied")
            }
            if live != text {
                issues = Proofreading.carry(issues, from: text, to: live)
                text = live
            }
            Log.write("write", "underlines: applied a fix (\(issue.rule))")
            FixTally.add()
            CorrectionTally.note(current, fix: fix, wrong: current.flagged(in: live), engine: engine)
            rewrite(to: Proofreading.apply(fix, to: current, in: live).text, dropping: current)
        case .dismiss:
            try? engine.dismiss(ruleKey: issue.rule, text: issue.flagged(in: text))
            forget(issue)
        case .dismissRule:
            try? engine.dismiss(ruleKey: issue.rule, text: nil)
            issues.removeAll { $0.rule == issue.rule }
            forget(issue)
        case .addToDictionary:
            let word = issue.flagged(in: text)
            _ = try? engine.addWord(word)
            issues.removeAll { $0.category == .spelling && $0.flagged(in: text).caseInsensitiveCompare(word) == .orderedSame }
            forget(issue)
        case .close, .rewrite, .acceptRewrite:
            // The card is already put away; the other two were handled above.
            break
        }
    }

    /// Takes a problem off the screen at once; the next check confirms it.
    private func forget(_ issue: WritingIssue) {
        issues.removeAll { $0.id == issue.id }
        needsCheck = true
        lastChange = Date()
        if let element { layout(in: element) }
    }

    /// Applies the first suggestion of every spelling and grammar problem in the field, and every snippet offered.
    func fixAll() {
        guard let element, !text.isEmpty, !applying else { return }
        let before = text
        let todo = issues
            // A snippet whose cue was typed goes in with the rest.
            .filter { !unlisted.contains($0.id) && ($0.category == .spelling || $0.category == .grammar || $0.category == .snippet) }
            .filter { !$0.suggestions.isEmpty && !Proofreading.likelyName($0, in: before) }
            .sorted { $0.start > $1.start }
        guard !todo.isEmpty else { return }
        Log.write("write", "underlines: fixing everything in the field (\(todo.count))")
        // Each fix goes in on its own, last to first, touching only its own words. One replacement from
        // the first mistake to the last would flatten whatever lies between them: bold and headings in a
        // rich document, links and code in a Markdown note. Working backwards keeps earlier positions true.
        let cursor = Self.selection(in: element)
        let app = appName.isEmpty ? "this app" : appName
        applying = true
        hideCard()
        Task { @MainActor in
            var current = before
            var done = 0
            var missed = 0
            var fixedIDs: Set<WritingIssue.ID> = []
            let original = before as NSString
            for (n, issue) in todo.enumerated() {
                guard let fix = issue.suggestions.first else { continue }
                // Key presses and pastes go to whatever is in front. Once the user has moved to another app
                // or another field, the rest are left alone and counted as not fixed.
                guard Self.stillTarget(element) else {
                    missed += todo.count - n
                    break
                }
                // The text is read again before each fix. In a web editor it changes as the cursor moves
                // (Obsidian shows a line's Markdown while the cursor is on it). A mistake is fixed where it was
                // found only if nothing has changed and its own letters are still there; otherwise it is found
                // by its letters and the words just before it on its line, nearest to where it was. Those come
                // from the text as it was checked: fixes go in last to first, so what lies before a mistake has
                // not been touched by the others. One that cannot be found is left alone.
                guard let live = TextInserter.text(of: element) else { break }
                let now = live as NSString
                let word = issue.flagged(in: before)
                guard !word.isEmpty else {
                    missed += 1
                    continue
                }
                var target = issue
                if live != current || issue.end > now.length || now.substring(with: issue.range) != word {
                    let line = original.lineRange(for: issue.range)
                    let from = max(line.location, issue.start - 12)
                    let context = original.substring(with: NSRange(location: from, length: issue.end - from))
                    var best: Int?
                    var at = 0
                    while at < now.length {
                        let hit = now.range(of: context, options: [], range: NSRange(location: at, length: now.length - at))
                        if hit.location == NSNotFound { break }
                        if best == nil || abs(hit.location - from) < abs(best! - from) { best = hit.location }
                        at = hit.location + 1
                    }
                    // Not in the text any more (an editor that only reports the pages on screen has moved on):
                    // counted as left, so the user is told and can press Fix all again.
                    guard let best else {
                        missed += 1
                        continue
                    }
                    let shift = best - from
                    target = WritingIssue(
                        start: issue.start + shift, end: issue.end + shift, rule: issue.rule, kind: issue.kind, message: issue.message,
                        priority: issue.priority, suggestions: issue.suggestions)
                }
                current = live
                let next = Proofreading.apply(fix, to: target, in: current).text
                guard next != current else { continue }
                let ok = await withCheckedContinuation { (reply: CheckedContinuation<Bool, Never>) in
                    let started = Self.rewrite(element, from: current, to: next, done: { reply.resume(returning: true) }, failed: { reply.resume(returning: false) })
                    if !started { reply.resume(returning: false) }
                }
                // A fix that could not be placed changed nothing (or was taken back). The rest still go in.
                current = TextInserter.text(of: element) ?? (ok ? next : current)
                if ok {
                    done += 1
                    FixTally.add()
                    CorrectionTally.note(issue, fix: fix, wrong: word, engine: engine)
                    fixedIDs.insert(issue.id)
                } else {
                    missed += 1
                }
                // An app that refuses the first two is refusing them all.
                if done == 0, missed >= 2 { break }
            }
            if missed > 0 {
                if done == 0 { onRefused?(app, Proofreading.fixAll(todo, in: before)) } else { onPartly?(done, missed) }
            }
            Log.write("write", "underlines: fixed \(done) of \(todo.count)")
            if let cursor, Self.stillTarget(element) {
                // The cursor goes back to where the user left it, moved along by the fixes that went in
                // before it. Also when some could not be placed: trying one leaves its words selected, and
                // the next key the user pressed would replace them.
                let at = Proofreading.position(cursor.location, afterFixing: todo.filter { fixedIDs.contains($0.id) }, in: before)
                TextInserter.setRange(NSRange(location: min(at, (current as NSString).length), length: 0), kAXSelectedTextRangeAttribute, in: element)
            }
            applying = false
            lookSoon()
            text = TextInserter.text(of: element) ?? current
            issues = Proofreading.carry(issues.filter { !fixedIDs.contains($0.id) }, from: before, to: text)
            needsCheck = true
            lastChange = Date()
            layout(in: element)
        }
    }

    /// The part of `updated` that differs from `before`: the words a fix puts in. Nil when nothing was
    /// added (a fix that only takes words out).
    static func changedWords(from before: String, to updated: String) -> String? {
        let old = Array(before), new = Array(updated)
        var start = 0
        while start < old.count, start < new.count, old[start] == new[start] { start += 1 }
        var endOld = old.count, endNew = new.count
        while endOld > start, endNew > start, old[endOld - 1] == new[endNew - 1] {
            endOld -= 1
            endNew -= 1
        }
        // Whole words, so "received" is copied and not the two letters that changed.
        while start > 0, !new[start - 1].isWhitespace { start -= 1 }
        while endNew < new.count, !new[endNew].isWhitespace { endNew += 1 }
        let words = String(new[start..<endNew]).trimmingCharacters(in: .whitespacesAndNewlines)
        return words.isEmpty ? nil : words
    }

    /// Changes the field to `updated`, and moves the underlines to match straight away.
    private func rewrite(to updated: String, dropping fixed: WritingIssue? = nil) {
        guard let element else { return }
        let before = text
        // The cursor and the page go back to where the user left them, moved along by however much the text
        // before them changed: a fix should not take the cursor to the fixed word or scroll the page there.
        let cursor = Self.selection(in: element)
        let page = Self.visibleRange(in: element)
        let app = appName.isEmpty ? "this app" : appName
        func place(_ range: NSRange) -> NSRange? { Self.carried(range, from: before, to: updated) }
        // Run once the new text is really in. Where a fix is pasted that is a moment later, and putting the
        // cursor back any sooner would send the paste to the old cursor instead of the word being fixed.
        let restore = {
            if let cursor, let moved = place(cursor) {
                TextInserter.setRange(moved, kAXSelectedTextRangeAttribute, in: element)
            }
            if let page, let moved = place(page), Self.visibleRange(in: element) != moved {
                TextInserter.setRange(moved, kAXVisibleCharacterRangeAttribute, in: element)
            }
        }
        // A fix that could not be placed leaves the words it tried selected; the cursor goes back where it was.
        let putBack = { if let cursor { TextInserter.setRange(cursor, kAXSelectedTextRangeAttribute, in: element) } }
        // What the fix would have put in, for the perch to offer when the app refuses it.
        let wanted = Self.changedWords(from: before, to: updated)
        guard Self.rewrite(element, from: before, to: updated, done: restore, failed: { [weak self] in
            putBack()
            self?.onRefused?(app, wanted)
        }) else {
            // The app would not put the cursor where the fix belongs. Nothing was changed.
            putBack()
            onRefused?(app, wanted)
            return
        }
        issues = Proofreading.carry(issues.filter { $0.id != fixed?.id }, from: before, to: updated)
        text = updated
        needsCheck = true
        lastChange = Date()
        layout(in: element)
    }

    /// Turns underlines off in the app being checked. It can be turned back on in the Library, under Writing style › By app.
    func turnOffForThisApp() {
        guard let appID else { return }
        var style = (try? engine.appStyle(bundleID: appID)) ?? AppStyle(bundleID: appID, appName: appName)
        style.underlinesEnabled = false
        try? engine.save(style)
        enabledAnswer = nil
        Log.write("write", "underlines: turned off for \(appName)")
    }

    /// Turns underlines off everywhere for a while.
    func pause(hours: Double) {
        pausedUntil = Date().addingTimeInterval(hours * 3600)
    }

    /// Ends a pause early.
    func resume() {
        pausedUntil = nil
        lookSoon()
    }

    /// Undoes whichever of the two is keeping suggestions off: the pause, or the switch for the app in front.
    func turnBackOn() {
        pausedUntil = nil
        guard let off = offApp, let appID else { return }
        // An app Chirp stays out of by default has no saved setting yet: turning it on makes one.
        var style = (try? engine.appStyle(bundleID: appID)) ?? AppStyle(bundleID: appID, appName: off)
        style.underlinesEnabled = true
        try? engine.save(style)
        enabledAnswer = nil
        offApp = nil
        lookSoon()
        Log.write("write", "underlines: turned back on for \(appName)")
    }

    // MARK: Accessibility helpers

    /// Electron apps only expose their text when asked; this is harmless everywhere else.
    private func prepare(_ pid: pid_t) {
        let appElement = AXUIElementCreateApplication(pid)
        if !preparedPIDs.contains(pid) {
            preparedPIDs.insert(pid)
            askedAt[pid] = .distantPast
        }
        // Electron apps describe their text only when asked, and an app that is still starting up loses
        // the request. So it is asked again every few seconds for as long as no text field shows.
        guard let last = askedAt[pid], Date().timeIntervalSince(last) > 3 else { return }
        askedAt[pid] = Date()
        AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    /// Whether a fix can still be sent to this field: its app is in front, and the keyboard has not moved to
    /// another text field in that app. Key presses and pastes go to whatever is in front, so this is asked
    /// before each. While Chirp's own bar holds the keyboard, as it does during a review, the app may report
    /// no field in focus, or its window; neither means the user has moved on, so only another text field counts.
    static func stillTarget(_ element: AXUIElement) -> Bool {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success,
            NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
        else { return false }
        guard let focused = TextInserter.focusedElement(), !CFEqual(focused, element) else { return true }
        var focusedPID: pid_t = 0
        guard AXUIElementGetPid(focused, &focusedPID) == .success, focusedPID == pid else { return true }
        return !isEditableText(focused)
    }

    /// Whether this is a text field Chirp may read and change. Password fields never count.
    static func isEditableText(_ element: AXUIElement) -> Bool {
        // A field that will not say what it is might be a password field: it is not read.
        // Having no subrole at all is an answer, and is fine.
        guard let role = TextInserter.stringValue(element, kAXRoleAttribute) else { return false }
        var sub: CFTypeRef?
        let answer = AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &sub)
        guard answer == .success || answer == .noValue || answer == .attributeUnsupported else { return false }
        let subrole = (sub as? String) ?? ""
        // Never read passwords. Some web views give the secure name as the role.
        guard subrole != (kAXSecureTextFieldSubrole as String), role != (kAXSecureTextFieldSubrole as String) else { return false }
        var settable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
        guard settable.boolValue else { return false }
        if role == (kAXTextAreaRole as String) || role == (kAXTextFieldRole as String) || role == (kAXComboBoxRole as String) {
            return true
        }
        // Editors that draw their own page (WordCraft, and others built the same way) call the document a
        // group, not a text area. It counts when it behaves like one: it has text, a cursor, and can say
        // where a range of its text is on screen.
        guard TextInserter.text(of: element) != nil else { return false }
        // (A WebKit page being edited keeps its cursor as text markers; `rangeValue` reads either.)
        guard TextInserter.rangeValue(element, kAXSelectedTextRangeAttribute) != nil else { return false }
        var names: CFArray?
        guard AXUIElementCopyParameterizedAttributeNames(element, &names) == .success, let names = names as? [String] else { return false }
        return names.contains(kAXBoundsForRangeParameterizedAttribute as String)
    }

    /// Whether a field is one box of a sign-in or payment form. What the field says about itself is asked
    /// once per field; whether its text is an address being typed is looked at every time.
    private func isSignIn(_ field: AXUIElement, text: String) -> Bool {
        let role = TextInserter.stringValue(field, kAXRoleAttribute) ?? ""
        guard role == (kAXTextFieldRole as String) || role == (kAXComboBoxRole as String) else { return false }
        if let known = signInAnswer, CFEqual(known.field, field) {
            return known.yes || SignInField.looksLikeAddress(text)
        }
        let labels = [kAXTitleAttribute, kAXDescriptionAttribute, kAXPlaceholderValueAttribute].map { TextInserter.stringValue(field, $0) }
        let yes = SignInField.matches(singleLine: true, labels: labels, id: TextInserter.stringValue(field, "AXDOMIdentifier"), text: nil)
        signInAnswer = (field, yes)
        return yes || SignInField.looksLikeAddress(text)
    }

    /// Screen rectangle (top-left origin) of a UTF-16 range of the element's text.
    static func bounds(of range: NSRange, in element: AXUIElement) -> CGRect? {
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let rangeValue = AXValueCreate(.cfRange, &cfRange) else { return nil }
        var out: CFTypeRef?
        guard
            AXUIElementCopyParameterizedAttributeValue(
                element, kAXBoundsForRangeParameterizedAttribute as CFString, rangeValue, &out) == .success,
            let out, CFGetTypeID(out) == AXValueGetTypeID()
        else { return nil }
        var rect = CGRect.zero
        return AXValueGetValue(out as! AXValue, .cgRect, &rect) ? rect : nil
    }

    /// The rectangles of a range, one per line it is on. A range that wraps would otherwise come back as one
    /// box around both lines.
    static func lineBounds(of range: NSRange, in element: AXUIElement) -> [CGRect] {
        guard range.length > 0, let first = line(of: range.location, in: element),
            let last = line(of: NSMaxRange(range) - 1, in: element), last > first, last - first < 8
        else { return bounds(of: range, in: element).map { [$0] } ?? [] }
        var out: [CGRect] = []
        for n in first...last {
            guard let whole = self.range(ofLine: n, in: element) else { return bounds(of: range, in: element).map { [$0] } ?? [] }
            let part = NSIntersectionRange(whole, range)
            guard part.length > 0, let rect = bounds(of: part, in: element) else { continue }
            out.append(rect)
        }
        return out
    }

    /// A piece of text inside a field, and where it sits in the field's whole text.
    struct TextRun {
        let range: NSRange
        let element: AXUIElement
        /// Code (a code block, or inline code), which is not checked.
        var code = false
    }

    /// The static-text pieces inside `element`, in order, each matched to its place in `text`.
    static func textRuns(in element: AXUIElement, text: String) -> [TextRun] {
        let whole = text as NSString
        var out: [TextRun] = []
        var cursor = 0
        var visited = 0
        func walk(_ e: AXUIElement, _ depth: Int, _ inCode: Bool) {
            visited += 1
            guard visited < 4000, depth < 14 else { return }
            // Web editors mark code blocks with a class on the line ("HyperMD-codeblock", "code-block").
            var names: CFTypeRef?
            AXUIElementCopyAttributeValue(e, "AXDOMClassList" as CFString, &names)
            let classes = (names as? [String]) ?? []
            let code = inCode || classes.contains { $0.lowercased().contains("code") }
            if TextInserter.stringValue(e, kAXRoleAttribute) == (kAXStaticTextRole as String),
                let value = TextInserter.stringValue(e, kAXValueAttribute), !value.isEmpty
            {
                let found = whole.range(of: value, options: [], range: NSRange(location: cursor, length: whole.length - cursor))
                if found.location != NSNotFound {
                    out.append(TextRun(range: found, element: e, code: code || isMonospace(e, value)))
                    cursor = NSMaxRange(found)
                }
                return
            }
            for child in TextInserter.children(of: e) { walk(child, depth + 1, code) }
        }
        walk(element, 0, false)
        return out
    }

    /// The parts of a WebKit page's text that sit inside a quotation: in Mail, the message being replied to.
    /// WebKit says how deeply quoted each piece is. Asking the page, not going by the wording, makes this
    /// hold for any app built on WebKit.
    static func quotedRanges(in element: AXUIElement, text: String) -> [NSRange] {
        let length = (text as NSString).length
        var out: [NSRange] = []
        var visited = 0
        func walk(_ e: AXUIElement, _ depth: Int) {
            visited += 1
            guard visited < 600, depth < 8 else { return }
            var level: CFTypeRef?
            AXUIElementCopyAttributeValue(e, "AXBlockQuoteLevel" as CFString, &level)
            if ((level as? NSNumber)?.intValue ?? 0) > 0 {
                // The page is asked where the whole quoted block is. Looking inside it is not needed, and a
                // quoted newsletter can be thousands of nested pieces.
                if let range = TextInserter.range(of: e, in: element), range.length > 0, NSMaxRange(range) <= length { out.append(range) }
                return
            }
            for child in TextInserter.children(of: e) { walk(child, depth + 1) }
        }
        for child in TextInserter.children(of: element) { walk(child, 1) }
        return out
    }

    /// Letters that are narrow in ordinary type, letters that are clearly wider, and the widest of those.
    /// Made once: the test below runs for every piece of text in a web editor.
    private static let narrowLetters = CharacterSet(charactersIn: "iljtf.,;:'|!1I")
    private static let wideLetters = CharacterSet(charactersIn: "mwMWOQGDHNUabdeghnopqsuvxyz023456789")
    private static let widestLetters = CharacterSet(charactersIn: "mwMW")

    /// Inline code carries no class or font through Accessibility, but it is set in a fixed-width font:
    /// a narrow letter and a wide one take the same room. (In ordinary text an "i" is far narrower than an "m".)
    static func isMonospace(_ element: AXUIElement, _ value: String) -> Bool {
        let text = value as NSString
        guard text.length >= 3, text.length <= 400 else { return false }
        let narrowSet = narrowLetters, wideSet = wideLetters
        var narrow: Int?, wide: Int?
        for i in 0..<min(text.length, 80) {
            guard let scalar = Unicode.Scalar(text.character(at: i)) else { continue }
            if narrow == nil, narrowSet.contains(scalar) { narrow = i }
            if wide == nil, widestLetters.contains(scalar) { wide = i }
            if narrow != nil, wide != nil { break }
        }
        if wide == nil {
            for i in 0..<min(text.length, 80) {
                if let scalar = Unicode.Scalar(text.character(at: i)), wideSet.contains(scalar), !narrowSet.contains(scalar) {
                    wide = i
                    break
                }
            }
        }
        guard let narrow, let wide,
            let a = bounds(of: NSRange(location: narrow, length: 1), in: element),
            let b = bounds(of: NSRange(location: wide, length: 1), in: element), a.width > 1, b.width > 1
        else { return false }
        return abs(a.width - b.width) < 0.6
    }


    /// Screen rectangles for `range`, one per line it sits on, asked of the text pieces it falls in.
    static func runBounds(of range: NSRange, in runs: [TextRun]) -> [CGRect] {
        var out: [CGRect] = []
        for run in runs {
            let part = NSIntersectionRange(run.range, range)
            guard part.length > 0 else { continue }
            let local = NSRange(location: part.location - run.range.location, length: part.length)
            // One character's height tells a single line from a range that wraps onto the next.
            let line = bounds(of: NSRange(location: local.location, length: 1), in: run.element)?.height ?? 0
            func split(_ r: NSRange, _ depth: Int) {
                guard let rect = bounds(of: r, in: run.element) else { return }
                if r.length <= 1 || depth > 6 || line <= 0 || rect.height <= line * 1.6 {
                    out.append(rect)
                } else {
                    let half = r.length / 2
                    split(NSRange(location: r.location, length: half), depth + 1)
                    split(NSRange(location: r.location + half, length: r.length - half), depth + 1)
                }
            }
            split(local, 0)
        }
        // Halves that ended up on the same line are joined back into one underline.
        var joined: [CGRect] = []
        for r in out {
            if let last = joined.last, abs(last.minY - r.minY) < 2 { joined[joined.count - 1] = last.union(r) } else { joined.append(r) }
        }
        return joined
    }

    /// The number of the line a character is on, when the app says.
    private static func line(of index: Int, in element: AXUIElement) -> Int? {
        var out: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXLineForIndexParameterizedAttribute as CFString, index as CFNumber, &out) == .success
        else { return nil }
        return (out as? NSNumber)?.intValue
    }

    /// The characters on one line, when the app says.
    private static func range(ofLine line: Int, in element: AXUIElement) -> NSRange? {
        var out: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXRangeForLineParameterizedAttribute as CFString, line as CFNumber, &out) == .success,
            let out, CFGetTypeID(out) == AXValueGetTypeID()
        else { return nil }
        var range = CFRange()
        return AXValueGetValue(out as! AXValue, .cfRange, &range) ? NSRange(location: range.location, length: range.length) : nil
    }

    /// The cursor or selection in a field (UTF-16), when the app says.
    static func selection(in element: AXUIElement) -> NSRange? {
        TextInserter.rangeValue(element, kAXSelectedTextRangeAttribute)
    }

    /// Where a cursor or selection made in `old` belongs in `new`, given that only one stretch changed.
    static func carried(_ selection: NSRange, from old: String, to new: String) -> NSRange? {
        let a = old as NSString, b = new as NSString
        var prefix = 0
        while prefix < min(a.length, b.length), a.character(at: prefix) == b.character(at: prefix) { prefix += 1 }
        var suffix = 0
        while suffix < min(a.length, b.length) - prefix, a.character(at: a.length - 1 - suffix) == b.character(at: b.length - 1 - suffix) {
            suffix += 1
        }
        let editEnd = a.length - suffix
        let delta = b.length - a.length
        func move(_ index: Int) -> Int {
            if index <= prefix { return index }
            if index >= editEnd { return index + delta }
            // Inside what changed: the end of the new text is the nearest sensible place.
            return b.length - suffix
        }
        let start = move(selection.location), end = move(NSMaxRange(selection))
        guard start <= end, end <= b.length else { return nil }
        return NSRange(location: start, length: end - start)
    }

    /// The characters that are on screen now, when the app says.
    static func visibleRange(in element: AXUIElement) -> NSRange? {
        guard let range = TextInserter.rangeValue(element, kAXVisibleCharacterRangeAttribute), range.length > 0 else { return nil }
        return range
    }

    /// The part of the screen the text shows through: the scrolling area around the field when there is one
    /// (the field itself is as tall as the whole document), cut down to the window.
    static func visibleFrame(of element: AXUIElement) -> CGRect? {
        var frame = self.frame(of: element)
        var current = element
        // An editor that draws its own page (WordCraft) has no scrolling area, and its document is as tall
        // as all its pages. The scroll bar beside it is as long as the part that shows, so it gives the
        // top and bottom (or left and right) of what is visible.
        var beside: CFTypeRef?
        // (Only where there is no scrolling area. Inside one, its own box is what shows, and a scroll bar
        // there can report a place that moves with the text: Mail's does.)
        if AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &beside) == .success, let beside,
            CFGetTypeID(beside) == AXUIElementGetTypeID(),
            TextInserter.stringValue(beside as! AXUIElement, kAXRoleAttribute) != (kAXScrollAreaRole as String)
        {
            for sibling in TextInserter.children(of: beside as! AXUIElement)
            where TextInserter.stringValue(sibling, kAXRoleAttribute) == (kAXScrollBarRole as String) {
                guard let bar = self.frame(of: sibling), let whole = frame, bar.width > 0, bar.height > 0 else { continue }
                if bar.height >= bar.width {
                    frame = CGRect(x: whole.minX, y: bar.minY, width: whole.width, height: bar.height).intersection(whole)
                } else {
                    frame = CGRect(x: bar.minX, y: whole.minY, width: bar.width, height: whole.height).intersection(whole)
                }
            }
        }
        for _ in 0..<5 {
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parent) == .success, let parent,
                CFGetTypeID(parent) == AXUIElementGetTypeID()
            else { break }
            current = parent as! AXUIElement
            let role = TextInserter.stringValue(current, kAXRoleAttribute) ?? ""
            if role == (kAXScrollAreaRole as String) || role == (kAXWindowRole as String), var outer = self.frame(of: current) {
                if role == (kAXScrollAreaRole as String) {
                    // A ruler along the top or side of the scrolling area covers the text that scrolls under it.
                    for child in TextInserter.children(of: current) where TextInserter.stringValue(child, kAXRoleAttribute) == (kAXRulerRole as String) {
                        guard let ruler = self.frame(of: child), ruler.intersects(outer) else { continue }
                        if ruler.width >= ruler.height {
                            let cut = max(0, ruler.maxY - outer.minY)
                            outer = CGRect(x: outer.minX, y: outer.minY + cut, width: outer.width, height: max(0, outer.height - cut))
                        } else {
                            let cut = max(0, ruler.maxX - outer.minX)
                            outer = CGRect(x: outer.minX + cut, y: outer.minY, width: max(0, outer.width - cut), height: outer.height)
                        }
                    }
                }
                frame = frame.map { $0.intersection(outer) } ?? outer
                if role == (kAXWindowRole as String) { break }
            }
        }
        return frame
    }

    /// Where an element is on screen, measured from the top-left of the main screen.
    static func frame(of element: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
            AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
            let posRef, let sizeRef
        else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posRef as! AXValue, .cgPoint, &point), AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
        else { return nil }
        return CGRect(origin: point, size: size)
    }

    /// How far a web editor's character positions were from its reported text, the last time it was measured.
    private static var lastDrift = 0

    /// Selects `wanted` by pressing arrow keys, for apps that ignore a request to select (WordCraft).
    /// Returns true only when the app then reports exactly that selection.
    static func keyboardSelect(_ wanted: NSRange, in element: AXUIElement) -> Bool {
        guard var at = selection(in: element) else { return false }
        // Too far to walk: a long trip of key presses is slow and easy to interrupt.
        guard abs(wanted.location - at.location) <= 2500, wanted.length <= 200 else { return false }
        func settle(until done: (NSRange) -> Bool) -> NSRange? {
            var now = selection(in: element)
            for _ in 0..<12 {
                if let now, done(now) { return now }
                usleep(30_000)
                now = selection(in: element)
            }
            return now
        }
        // A selection is collapsed to its start first, so the walk begins from a plain cursor.
        if at.length > 0 {
            TextInserter.pressArrow(right: false, shift: false, times: 1)
            guard let now = settle(until: { $0.length == 0 }), now.length == 0 else { return false }
            at = now
        }
        // Walk to the start. One press is not always one character (emoji, line ends), so the cursor is
        // read back and the walk corrected a few times.
        for _ in 0..<5 {
            let delta = wanted.location - at.location
            if delta == 0 { break }
            let before = at
            TextInserter.pressArrow(right: delta > 0, shift: false, times: abs(delta))
            guard let now = settle(until: { $0.location == wanted.location }) else { return false }
            if now == before { return false }  // the keys are not reaching the app
            at = now
        }
        guard at.location == wanted.location, at.length == 0 else { return false }
        if wanted.length > 0 {
            for _ in 0..<5 {
                guard let now = selection(in: element) else { return false }
                let missing = wanted.length - now.length
                if now.location == wanted.location, missing == 0 { break }
                guard now.location == wanted.location, missing > 0 else { return false }
                TextInserter.pressArrow(right: true, shift: true, times: missing)
                _ = settle(until: { $0 == wanted })
            }
        }
        return settle(until: { $0 == wanted }) == wanted
    }

    /// Changes the other app's text from `text` to `updated` by replacing only the part that differs.
    /// Returns false, having changed nothing, when the app would not select the text to be replaced.
    /// `done` is called once the new text is in: straight away for a direct edit, a moment later for a paste.
    /// `failed` is called later if a pasted fix landed in the wrong place and had to be undone.
    @discardableResult
    static func rewrite(
        _ element: AXUIElement, from text: String, to updated: String, done: (() -> Void)? = nil, failed: (() -> Void)? = nil
    ) -> Bool {
        let old = text as NSString
        // Chromium and Electron editors (Obsidian, Slack, Chrome) do select a range, but editing the
        // selection directly puts the new text beside the old instead of over it ("recieeive"). There the fix
        // is pasted over the selection.
        var names: CFArray?
        AXUIElementCopyAttributeNames(element, &names)
        let chromium = (names as? [String])?.contains("ChromeAXNodeId") ?? false
        // The smallest change: what the two texts share at the start and the end is left alone. Web editors
        // do not reliably move a bare cursor, so there an insertion takes the letter before it along; and a
        // change that only removes letters always does, because pasting nothing does nothing.
        let (wanted, replacement) = Proofreading.smallestEdit(from: text, to: updated, neverBareCursor: chromium)
        guard TextInserter.setRange(wanted, kAXSelectedTextRangeAttribute, in: element) else {
            Log.write("write", "underlines: this app would not let Chirp select the text to change")
            return false
        }
        // Some apps (WordCraft) answer yes and leave the cursor where it was. Pasting then would put the fix
        // in the wrong place, so the selection is read back first, with a moment for apps that move it late.
        var landed = selection(in: element)
        for _ in 0..<3 where landed != wanted {
            usleep(50_000)
            landed = selection(in: element)
        }
        // (A web editor is checked by what it selected, below: near the end of a note it reports a clipped
        // range even when the selection can be lined up.)
        if landed != wanted, !chromium {
            // The app does report where its cursor is, so the cursor is walked there with the arrow keys
            // and the words selected with Shift, the way a person would. Checked before anything is replaced.
            guard keyboardSelect(wanted, in: element) else {
                Log.write("write", "underlines: the app said it selected the text but did not; nothing changed")
                return false
            }
            Log.write("write", "underlines: selected the text with the arrow keys")
        }
        // A web editor can count characters differently from the text it reports (headings, lists and
        // code blocks each shift it), so the range it was given is not always the words it selected. What it
        // really selected is read back; when that is wrong, a longer stretch around the spot is selected to
        // find how far off it is, and the selection is made again with that corrected.
        var chromiumAfter: String?
        if chromium, wanted.length > 0 {
            let expected = old.substring(with: wanted)
            func selected() -> String? {
                usleep(60_000)
                return TextInserter.stringValue(element, kAXSelectedTextAttribute)
            }
            func select(_ r: NSRange) -> Bool {
                guard r.location >= 0 else { return false }
                return TextInserter.setRange(r, kAXSelectedTextRangeAttribute, in: element)
            }
            // The words around the spot, on its own line. One right letter can be a coincidence; a dozen
            // characters either side cannot. The amount the app is off by is the same along a line.
            let line = old.lineRange(for: wanted)
            let from = max(line.location, wanted.location - 12)
            var to = min(NSMaxRange(line), NSMaxRange(wanted) + 12)
            while to > NSMaxRange(wanted), let scalar = Unicode.Scalar(old.character(at: to - 1)), CharacterSet.newlines.contains(scalar) { to -= 1 }
            let around = NSRange(location: from, length: to - from)
            let context = old.substring(with: around)
            chromiumAfter = (context as NSString).replacingCharacters(
                in: NSRange(location: wanted.location - around.location, length: wanted.length), with: replacement)
            func lines(up drift: Int) -> Bool {
                select(NSRange(location: around.location - drift, length: around.length))
                    && selected().map { $0.replacingOccurrences(of: "\u{00a0}", with: " ") } == context.replacingOccurrences(of: "\u{00a0}", with: " ")
            }
            if !lines(up: 0) {
                func nearest(_ piece: String, to target: Int) -> Int? {
                    var best: Int?
                    var at = 0
                    while at < old.length {
                        let hit = old.range(of: piece, options: [], range: NSRange(location: at, length: old.length - at))
                        if hit.location == NSNotFound { break }
                        if best == nil || abs(hit.location - target) < abs(best! - target) { best = hit.location }
                        at = hit.location + 1
                    }
                    return best
                }
                // A first guess from what the app selects when asked for the start of this line, then the
                // amounts around it and around the last one that worked.
                var guesses: [Int] = [lastDrift]
                let probe = NSRange(location: line.location, length: min(48, max(1, line.length - 1)))
                if select(probe), let got = selected() {
                    let parts = got.components(separatedBy: .newlines).filter { $0.count >= 4 }
                    if let first = parts.first, got.hasPrefix(first), let at = nearest(first, to: probe.location) {
                        guesses.append(at - probe.location)
                    }
                    if let last = parts.last, got.hasSuffix(last), let at = nearest(last, to: NSMaxRange(probe)) {
                        guesses.append(at + (last as NSString).length - NSMaxRange(probe))
                    }
                }
                var order: [Int] = []
                for g in guesses { for step in [0, 1, -1, 2, -2, 3, -3, 4, -4] where !order.contains(g + step) { order.append(g + step) } }
                guard let found = order.prefix(30).first(where: { $0 != 0 && lines(up: $0) }) else {
                    Log.write("write", "underlines: the app's selection could not be lined up; nothing changed")
                    return false
                }
                if found != lastDrift { Log.write("write", "underlines: the app counts characters \(found) off here; corrected") }
                lastDrift = found
                guard select(NSRange(location: wanted.location - found, length: wanted.length)), selected() == expected else {
                    Log.write("write", "underlines: the app's selection could not be lined up; nothing changed")
                    return false
                }
            } else {
                guard select(wanted), selected() == expected else { return false }
            }
        }
        // Some apps (Mail) say yes to a direct edit and then do nothing, so the result is read back; when
        // the text is unchanged the fix is pasted over the selection instead.
        // A WebKit page being edited (Mail's compose window) is the same, and is not asked at all: the fix
        // goes in by paste.
        if chromium || TextInserter.usesTextMarkers(element)
            || AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, replacement as CFString) != .success
            || TextInserter.text(of: element) == text
        {
            Task { @MainActor in
                // A web editor keeps its own cursor and takes a moment to follow the selection just set.
                // Pasting before it has would put the fix where the user last clicked.
                if chromium { try? await Task.sleep(for: .milliseconds(220)) }
                // A paste goes to whatever is in front. If the user has moved to another app or another field
                // since the text was selected, nothing is pasted (and so there is nothing to undo).
                guard UnderlineController.stillTarget(element) else {
                    Log.write("write", "underlines: the text field was no longer in front, so the fix was not pasted")
                    failed?()
                    return
                }
                _ = await TextInserter.pasteOverSelection(replacement)
                // A web editor can show a line differently once the cursor is on it (Obsidian shows its
                // Markdown), so the whole text is not compared there: the fixed words must be where the
                // old ones were. Web editors also swap in non-breaking and zero-width spaces, which are
                // not differences. And a busy app can take a second to show the change, so it is looked
                // for several times before the paste is called wrong.
                func plain(_ s: String) -> String {
                    s.replacingOccurrences(of: "\u{00a0}", with: " ").replacingOccurrences(of: "\u{200b}", with: "")
                }
                var landed = false
                // Text that is still exactly as it was has not taken the paste, or not yet: it is looked at
                // again, and is never counted as the fix having gone in.
                var unchanged = false
                for wait in [300, 200, 250, 350, 500] {
                    try? await Task.sleep(for: .milliseconds(wait))
                    let now = TextInserter.text(of: element)
                    landed = chromiumAfter.map { fixed in now.map { plain($0).contains(plain(fixed)) } ?? true }
                        ?? (now == nil || now.map(plain) == plain(updated))
                    unchanged = now == text
                    if landed { break }
                }
                guard !landed else {
                    done?()
                    return
                }
                guard !unchanged else {
                    // Nothing went in, so there is nothing to take back: undo here would undo the user's own last edit.
                    Log.write("write", "underlines: the app did not take a pasted fix; nothing changed")
                    failed?()
                    return
                }
                // The paste landed somewhere else. Take it back and say so, rather than leave a wrong word.
                TextInserter.pressUndo()
                Log.write("write", "underlines: a pasted fix landed in the wrong place and was undone")
                failed?()
            }
        } else {
            done?()
        }
        return true
    }
}

extension Array {
    /// The element at `index`, or nil when there is none, for indexes that come from outside (debug links).
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

/// The transparent, click-through window the underlines are drawn in.
@MainActor
final class UnderlineOverlay {
    private var window: NSWindow?
    private let model = UnderlineOverlayModel()

    /// Draws these underlines and sentence birds across all screens, or hides the window when there are none.
    func show(_ underlines: [Underline], birds: [SentenceBird] = []) {
        if underlines.isEmpty {
            window?.orderOut(nil)
            model.underlines = []
            model.birds = []
            return
        }
        let frame = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }
        let w = window ?? {
            // A panel, like the perch: a plain window is not shown over another app's full-screen window.
            let w = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            w.isFloatingPanel = true
            w.hidesOnDeactivate = false
            w.becomesKeyOnlyIfNeeded = true
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false
            w.ignoresMouseEvents = true  // typing and clicks go straight through to the app underneath
            w.level = .floating
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: UnderlineOverlayView(model: model))
            return w
        }()
        window = w
        // Underlines lie on another app's page, so they take the Mac's light or dark setting, not Chirp's own:
        // the darker red belongs on a white page even when Chirp itself is set to dark.
        let dark = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
        w.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        if w.frame != frame { w.setFrame(frame, display: false) }
        model.origin = frame.origin
        model.height = frame.height
        model.underlines = underlines
        model.birds = birds
        w.orderFrontRegardless()
    }
}

/// What the overlay window draws: the underlines, and the corner and height of the area it covers, for
/// turning screen positions into positions in the window.
@MainActor
@Observable
final class UnderlineOverlayModel {
    var underlines: [Underline] = []
    var birds: [SentenceBird] = []
    var origin = CGPoint.zero
    var height: CGFloat = 0
}

/// Draws each underline as a short coloured line just under its words.
struct UnderlineOverlayView: View {
    let model: UnderlineOverlayModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        return ZStack(alignment: .topLeading) {
            lines(dark: dark)
            // The bird after each sentence that can be fixed. Drawn here, in the window clicks pass through:
            // the pointer over it is noticed by the same watcher that notices it over an underline.
            ForEach(Array(model.birds.enumerated()), id: \.offset) { _, bird in
                Bird(mood: .idle, size: bird.rect.width)
                    .position(x: bird.rect.midX - model.origin.x, y: model.height - (bird.rect.midY - model.origin.y))
            }
        }
        .accessibilityHidden(true)
    }

    private func lines(dark: Bool) -> some View {
        Canvas { ctx, _ in
            for u in model.underlines {
                // Convert from screen coordinates (origin bottom-left) to this view (origin top-left).
                // Drawn a little short at each end, so two problems side by side read as two lines.
                let inset = min(1.5, u.rect.width / 4)
                let x = u.rect.minX - model.origin.x + inset
                // The app's box for a line includes the space under the letters; the underline sits just
                // inside it, so it reads as under these words and not over the next line.
                let y = model.height - (u.rect.minY - model.origin.y) - max(1, min(3, u.rect.height * 0.12))
                // Each kind has its own line, not only its colour (`UnderlineLook`): spelling wavy, grammar
                // solid, style dashed, a snippet's cue dotted (an offer, not a mistake); a likely name is the
                // spelling line, thinner and fainter. A wave is lifted by half its height, so it stays in the box and off the letters.
                let look = UnderlineLook.of(u.issue.category, likelyName: u.likelyName, dark: dark)
                let path = Path(look.path(from: x, to: x + u.rect.width - inset * 2, y: y - look.amplitude / 2))
                let colour = Color(nsColor: u.issue.category.color)
                ctx.stroke(
                    path, with: .color(colour.opacity(look.opacity)),
                    style: StrokeStyle(lineWidth: look.width, lineCap: look.dash == nil ? .butt : .round, lineJoin: .round, dash: look.dash ?? []))
            }
        }
    }
}

/// What shows when the pointer is on a sentence bird: what it does, and the keys for it.
struct SentenceHint: View {
    let keys: String

    var body: some View {
        HStack(spacing: 7) {
            Text("Fix this sentence").font(.system(size: 12.5)).foregroundStyle(PerchStyle.text)
            if !keys.isEmpty { PerchKey(text: keys) }
        }
        .padding(.leading, 11).padding(.trailing, 9).frame(height: 28)
        .background(PerchStyle.fill, in: Capsule())
        .overlay(Capsule().strokeBorder(PerchStyle.line))
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Fix this sentence, \(keys)")
    }
}

/// A picture of the sentence birds for some text, without another app: the text laid out as a field would
/// lay it out, the lines under its problems, the bird after each sentence that has a fix, and the hint.
@MainActor
enum SentenceBirdShot {
    /// `caret`: where the cursor is (the end of the text when nil). `topRoom`: how far the field's top edge
    /// is above the first line (the picture's own margin is 20).
    static func write(text: String, issues: [WritingIssue], hint: Bool, dark: Bool, caret: Int? = nil, topRoom: CGFloat = 0, size: CGFloat = 15, to path: String) {
        let width: CGFloat = 520
        let font = NSFont.systemFont(ofSize: size)
        let storage = NSTextStorage(string: text, attributes: [.font: font])
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: width - 40, height: 2000))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        let height = used.height + 40 + (hint ? 44 : 8)
        // The box of a range, in the picture's top-left coordinates, last line only for a range over a break.
        func boxes(_ range: NSRange) -> [CGRect] {
            var out: [CGRect] = []
            let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            layout.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: container) { r, _ in
                out.append(r.offsetBy(dx: 20, dy: 20))
            }
            return out
        }
        let model = UnderlineOverlayModel()
        model.height = height
        // The overlay's own coordinates are Cocoa's (origin bottom-left).
        func flipped(_ r: CGRect) -> CGRect { CGRect(x: r.minX, y: height - r.maxY, width: r.width, height: r.height) }
        model.underlines = issues.flatMap { issue in
            boxes(issue.range).enumerated().map { n, r in
                Underline(issue: issue, rect: flipped(r), piece: n, likelyName: Proofreading.likelyName(issue, in: text))
            }
        }
        let ns = text as NSString
        // One bird, for the sentence at the cursor.
        model.birds = SentenceBirdRule.sentence(in: text, caret: caret ?? ns.length, issues: issues).flatMap { fix -> SentenceBird? in
            var lastCharacter = NSMaxRange(fix.range) - 1
            while lastCharacter > fix.range.location, lastCharacter < ns.length, [32, 9, 10, 13].contains(ns.character(at: lastCharacter)) { lastCharacter -= 1 }
            guard let end = boxes(NSRange(location: lastCharacter, length: 1)).last else { return nil }
            var next = NSMaxRange(fix.range)
            while next < ns.length, [32, 9].contains(ns.character(at: next)) { next += 1 }
            let following = next < ns.length ? boxes(NSRange(location: next, length: 1)).first : nil
            // The line above the last character, as a field that says where its lines are.
            var line = NSRange()
            layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: lastCharacter), effectiveRange: &line)
            var textAbove: [CGRect] = []
            if line.location > 0 {
                var above = NSRange()
                layout.lineFragmentRect(forGlyphAt: line.location - 1, effectiveRange: &above)
                let chars = layout.characterRange(forGlyphRange: above, actualGlyphRange: nil)
                textAbove = boxes(chars)
            }
            guard let place = SentenceBirdRule.place(end: end, next: following, right: width - 20, top: 20 - topRoom, textAbove: textAbove) else { return nil }
            return SentenceBird(fix: fix, rect: flipped(place), line: flipped(end))
        }.map { [$0] } ?? []
        let first = model.birds.first
        let view = ZStack(alignment: .topLeading) {
            Text(text).font(.system(size: size)).foregroundStyle(Color.ink).frame(width: width - 40, alignment: .leading).padding(20)
            UnderlineOverlayView(model: model).frame(width: width, height: height)
            if hint, let first {
                SentenceHint(keys: KeyboardShortcuts.getShortcut(for: .fixSentence)?.description ?? "")
                    .shadow(color: PerchStyle.shadow.opacity(0.5), radius: 8, y: 3)
                    .offset(x: max(8, first.rect.minX - 10), y: height - first.line.minY + 6)
            }
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .background(Color.card)
        .environment(\.colorScheme, dark ? .dark : .light)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        if let image = renderer.cgImage {
            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
    }
}

/// The options for writing checks: the deeper check, underlines in other apps, and the shortcuts.
struct WriteOptions: View {
    @Environment(UnderlineController.self) private var underlines
    @State private var deep = GrammarChecker.deepEnabled
    @State private var deepEverywhere = GrammarChecker.deepInOtherApps
    /// False where the shortcut recorders are shown somewhere else on the same screen.
    var showShortcuts = true

    var body: some View {
        @Bindable var underlines = underlines
        Form {
            Section("Deeper grammar check") {
                Toggle("Use the language model to catch what the instant check misses", isOn: $deep)
                    .onChange(of: deep) { _, on in GrammarChecker.deepEnabled = on }
                Toggle("Also in other apps", isOn: $deepEverywhere)
                    .onChange(of: deepEverywhere) { _, on in GrammarChecker.deepInOtherApps = on }
                    .disabled(!deep)
                    .help("Keeps the language model in memory while you type. Best on Macs with 16 GB or more.")
            }
            Section("In other apps") {
                Toggle("Underline spelling and grammar as I type", isOn: $underlines.enabled)
                LabeledContent("Right now", value: underlines.status.isEmpty ? "Waiting" : underlines.status)
                if underlines.pausedUntil != nil {
                    Button("Turn underlines back on") { underlines.resume() }
                }
                if showShortcuts {
                    KeyboardShortcuts.Recorder("Fix writing", name: .writePanel)
                    KeyboardShortcuts.Recorder("Rephrase the selected text", name: .rephrase)
                    KeyboardShortcuts.Recorder("Fix the sentence at the cursor", name: .fixSentence)
                }
            }
            Text("Underlines work in apps that report where their text is on screen, such as Notes, Mail and TextEdit. Click an underlined word for its fix, or click Fix on Chirp’s bar to see every suggestion. The sentence shortcut applies all the fixes in the sentence the cursor is in. Turn underlines on or off per app in the Library, under Writing style › By app.")
                .font(.caption).foregroundStyle(Color.quiet)
        }
        .formStyle(.grouped)
        .frame(minWidth: 480, minHeight: 500)
    }
}
