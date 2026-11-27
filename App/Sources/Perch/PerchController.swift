import AppKit
import ChirpCore
import KeyboardShortcuts
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// How much of the perch is on screen when Chirp is doing nothing.
enum PerchPresence: String, CaseIterable, Identifiable {
    /// A faint wire only.
    case quiet
    /// The bird on its wire.
    case present
    /// The bird and the four actions.
    case full
    /// Nothing until Chirp is working.
    case hidden

    var id: String { rawValue }
    var title: String {
        switch self {
        case .quiet: "Quiet"
        case .present: "Present"
        case .full: "Full"
        case .hidden: "Hidden"
        }
    }
}

/// Where along the bottom of the screen the perch sits.
enum PerchPosition: String, CaseIterable, Identifiable {
    case left, centre, right

    var id: String { rawValue }
    var title: String {
        switch self {
        case .left: "Bottom left"
        case .centre: "Bottom centre"
        case .right: "Bottom right"
        }
    }
}

extension KeyboardShortcuts.Name {
    /// Brings the Library window forward from any app.
    // These four are right Option and a letter (see `ShortcutLayout`).
    static let openLibrary = Self("openLibrary", initial: .init(.o, modifiers: [.option]))
    /// Starts a meeting ("Record a Meeting"), or stops the recording under way.
    static let recordMeeting = Self("recordMeeting", initial: .init(.m, modifiers: [.option]))
    /// Summarizes the selection, the text the cursor is in, or the page in front.
    static let summarize = Self("summarize", initial: .init(.u, modifiers: [.option]))
}

/// Light, dark, or whatever macOS is set to.
@MainActor
enum Appearance {
    /// "light", "dark", or empty to follow macOS. Saved, and applied as soon as it is set.
    static var choice: String {
        get { UserDefaults.standard.string(forKey: "appearance") ?? "" }
        set {
            UserDefaults.standard.set(newValue, forKey: "appearance")
            apply()
        }
    }

    /// Puts the saved choice on every Chirp window, the perch included. Called once at launch.
    static func apply() {
        NSApp.appearance = choice == "light" ? NSAppearance(named: .aqua) : choice == "dark" ? NSAppearance(named: .darkAqua) : nil
    }
}

/// The perch: one small bar at the bottom of the screen that is Chirp's whole presence while you work.
/// It shows the four actions at rest, and turns into the live state of whatever Chirp is doing:
/// listening, recording a meeting, reading aloud, or a one-line message.
@MainActor
@Observable
final class PerchController {
    /// The one perch, for code that has no other way to reach it (the Dock drop, the Library's Add menu).
    static var shared: PerchController?

    /// What the bird says in its bubble: a status that passes, or a call offer that waits for an answer.
    struct Saying: Equatable {
        /// Tells one from the next, so a new one takes the bubble over in place.
        var id: String
        /// Words shown first and heavier (which call it is), if any.
        var lead: String?
        var text: String
        var isError: Bool
        /// The names of its buttons, the main one first.
        var buttons: [String]
        /// A status passes: it has an ×, goes on a click and on Escape, and after three seconds. A call
        /// offer does not: it stays until one of its buttons is pressed or the call is gone.
        var passes: Bool
    }

    /// One line of words on the perch, with an optional button. Each has its own id, so the same words
    /// said twice count as two notices and the second gets its full time on screen.
    struct Notice: Equatable {
        var text: String
        var actionTitle: String?
        /// Something went wrong. It gets a red dot and stays until it is dismissed.
        var isError = false
        var id = UUID()
        static func == (a: Notice, b: Notice) -> Bool { a.id == b.id }
    }

    /// How much of the perch shows while Chirp is doing nothing. Saved between launches.
    var presence: PerchPresence {
        didSet { UserDefaults.standard.set(presence.rawValue, forKey: "perchPresence") }
    }
    /// Where along the bottom of the screen the perch sits, as chosen in Settings. Dragging the perch
    /// to a bottom spot sets this too; anywhere else it keeps its last value.
    var position: PerchPosition {
        didSet {
            UserDefaults.standard.set(position.rawValue, forKey: "perchPosition")
            if !syncingSpot { setSpot(position.spot) }
        }
    }
    /// Tuck away under the screen's edge while a full-screen app is in front (a film, a presentation).
    var hideInFullScreen: Bool {
        didSet { UserDefaults.standard.set(hideInFullScreen, forKey: "perchHideInFullScreen") }
    }
    /// True while the pointer has rested on the perch.
    var hovering = false
    /// The line being shown now, if any. It takes the bar over from everything else.
    private(set) var notice: Notice?
    /// What the button on the current notice does.
    private var noticeAction: (() -> Void)?
    /// All of a long status is showing, after "More" was pressed.
    private(set) var noticeExpanded = false
    /// How long the bubble has been showing, and how long it stays by itself.
    @ObservationIgnored private var noticeAge = 0.0
    @ObservationIgnored private var noticeLife = 3.0
    /// Where the bubble is drawn in the panel, so clicks reach it and its time can wait for the pointer.
    @ObservationIgnored var bubbleFrame = CGRect.zero
    /// Where the whole surface is, for the bubble to be placed against. Unlike `surfaceFrame` this is
    /// watched, so the bubble follows the perch.
    var bubbleSurface = CGRect.zero

    // Where the perch is. The functions that work on these are in PerchPlacement.swift.

    /// Where the perch sits on the display it is on.
    var spot = PerchSpot.bottomCentre
    /// True while `position` is being set to match a spot, so it does not move the perch again.
    @ObservationIgnored var syncingSpot = false
    /// The part of the panel the perch may use: clear of the menu bar and the Dock. In the panel's own
    /// coordinates (origin top left).
    var bounds = CGRect(x: 0, y: 0, width: 1440, height: 900)
    /// True while the perch is being dragged.
    var dragging = false
    /// The middle of the bar while it is dragged, in the panel's coordinates.
    var dragCentre = CGPoint.zero
    /// The landing spot the dragged perch is nearest, if it is near one.
    var nearSpot: PerchSpot?
    /// From the middle of the bar to the pointer when the drag began.
    @ObservationIgnored var grab = CGSize.zero
    /// The size of the bar at rest, lying flat. The landing spots are drawn this size.
    var barSize: CGSize { PerchStyle.restSize(upright: false) }
    /// Which action the pointer was resting on when the bar grew taller (0…4, then More as 5), and where
    /// the middle of that action was along the bar, in the panel's coordinates. The taller bar is placed
    /// so the same action stays under the pointer.
    var hoverAnchor: (item: Int, at: CGFloat)?
    /// A test link is holding the perch as if dragged; it stays until the link lets go.
    @ObservationIgnored var heldByLink = false
    /// True while the perch is under the screen's edge with only a sliver showing.
    var tucked = false
    /// The pointer came to the edge, so the tucked perch is out for now.
    @ObservationIgnored var revealed = false
    /// A shortcut was used: the perch stays out until this time.
    @ObservationIgnored var revealUntil = Date.distantPast
    /// A full-screen app is in front on the perch's display.
    var frontFullScreen = false
    /// Set by a test link to act as if a full-screen app were (or were not) in front.
    @ObservationIgnored var debugFullScreen: Bool?
    /// "Hide for an Hour": nothing shows at rest until this time.
    var hiddenUntil: Date?
    /// "Hide Until I Use a Shortcut": nothing shows at rest until a Chirp shortcut is pressed.
    var hiddenUntilShortcut = false
    /// The display the perch is on.
    @ObservationIgnored var screen: NSScreen?
    /// How tall the part above the bar may be, for each kind of thing shown there. Pulling the handle
    /// changes it, and it is kept between launches.
    var bodyHeights: [String: Double] = [:]
    /// The height when a pull on the handle began.
    @ObservationIgnored var pullFrom: Double?
    /// Set by a test link to show one of the busy bars without the work behind it.
    var debugBar: PerchBar?
    /// The work in progress was put out of sight with its ×. The bar is back to the actions until it ends.
    var workHidden = false
    /// The meeting notes panel that opens upward from the perch.
    var showMeetingNotes = false
    /// The More menu as a test link last built it.
    @ObservationIgnored private var moreSeen: [String: Any] = [:]
    /// Watches for Escape while the rephrase card is open, so the key closes it.
    private var escapeMonitor: Any?
    /// The list of writing suggestions that opens upward from the perch. Closing it also ends a
    /// keyboard review and hands the keyboard back.
    var showFixes = false {
        didSet { if !showFixes, oldValue { endKeyboardReview() } }
    }
    /// The suggestion the keyboard is on, while the list is being worked through without the mouse.
    private(set) var fixCursor: Int?
    /// Takes the arrow, Return, Delete and Escape keys while the suggestions are worked through by keyboard.
    private var reviewMonitor: Any?

    let app: AppModel
    let dictation: DictationController
    let recorder: MeetingRecorder
    let detector: MeetingDetector
    let reader: ReadController
    let underlines: UnderlineController
    let selection: SelectionPanelController
    /// The note the perch grows into.
    let notes: NoteController

    /// Which actions are on the perch and which in the extended area. Saved as it changes.
    var arrangement: PerchArrangement {
        didSet {
            UserDefaults.standard.set(arrangement.json, forKey: "perchArrangement")
            PerchStyle.actionCount = shownActions.bar.count
            PerchStyle.extendedCount = extendedOpen ? shownActions.extended.count : -1
        }
    }
    /// The extended area is drawn open. Only the chevron opens and closes it: opening on hover was
    /// jittery, and the hidden items are shown only when the user chooses to have them open. It is
    /// drawn only at rest, and comes back as it was when the perch returns to rest.
    var extendedOpen = false {
        didSet { PerchStyle.extendedCount = extendedOpen ? shownActions.extended.count : -1 }
    }
    /// The user's choice: the chevron was pressed open, and stays so until it is pressed again.
    var extendedPinned = false
    /// Customize Perch is open (on the Settings window's Perch tab).
    var customizing = false
    /// The actions shown with the features that are on.
    var shownActions: (bar: [PerchAction], extended: [PerchAction]) { arrangement.shown(Features.shared.set) }

    /// The clear window the perch is drawn in. It covers the display the perch is on, so the perch can
    /// sit anywhere on it; clicks outside the drawn part pass through to the app underneath.
    let panel = PerchPanel()
    /// Runs `tick` ten times a second for as long as the app is open.
    private var timer: Timer?
    /// Where the surface is drawn in the panel, so the pointer can be tested against it.
    @ObservationIgnored var surfaceFrame = CGRect.zero
    // Where the bar row and the bird are is worked out from the surface's frame and the bar's own
    // measurements, not measured: frames measured inside the surface were left behind, part-way through
    // the move, whenever the perch slid to a new spot or changed between flat and upright.

    /// Where the bar row is drawn in the panel: what a drag picks up.
    var barFrame: CGRect {
        let s = surfaceFrame
        let tall = content == .tiles
        if upright {
            let width = min(s.width, tall ? PerchStyle.tallColumn : PerchStyle.barHeight)
            return CGRect(x: spot == .rightEdge ? s.maxX - width : s.minX, y: s.minY, width: width, height: s.height)
        }
        let height = min(s.height, tall ? PerchStyle.tallBarHeight : PerchStyle.barHeight)
        // Holding something, the bar is the bottom row, or the top one when the surface opens downward.
        return CGRect(x: s.minX, y: opensDown ? s.minY : s.maxY - height, width: s.width, height: height)
    }

    /// Where the bird is drawn in the panel: a right click there opens its menu, and a status bubble
    /// points at it.
    var birdFrame: CGRect {
        let bar = barFrame
        let tall = content == .tiles
        let inset = PerchStyle.inset(tall: tall, upright: upright)
        let box = PerchStyle.birdBox(tall: tall, upright: upright)
        return upright
            ? CGRect(x: bar.minX, y: bar.minY + inset, width: bar.width, height: min(box, bar.height))
            : CGRect(x: bar.minX + inset, y: bar.minY, width: min(box, bar.width), height: bar.height)
    }
    /// The recording whose notes were being written at the last tick, so the moment they finish is noticed.
    private var wasWritingNotes: Int64?
    /// A recording whose notes have just been written, waiting for the recorder to finish before it is shown.
    private var notesToShow: Int64?
    /// The recording whose finished notes are shown in a card above the perch; nil when no such card is open.
    var finished: SavedItem?

    /// Opens the recording from the card in the Library.
    func openFinished() {
        guard let item = finished else { return }
        finished = nil
        app.open(item)
        AppDelegate.showMain()
    }

    /// Copies the notes from the card.
    func copyFinished() {
        guard let item = finished else { return }
        RichCopy.copy(markdown: item.summary)
        say("Copied", seconds: 2)
    }

    /// Reads the notes from the card aloud.
    func readFinished() {
        guard Features.on(.read), let item = finished, !item.summary.isEmpty else { return }
        finished = nil
        reader.readOnce(DocumentImporter.Imported(title: item.title, text: MarkdownLines.plain(item.summary), source: "Notes"))
    }

    /// Builds the panel, starts following the pointer, and registers the shortcuts and the test links.
    init(
        app: AppModel, dictation: DictationController, recorder: MeetingRecorder, detector: MeetingDetector,
        reader: ReadController, underlines: UnderlineController, selection: SelectionPanelController
    ) {
        self.app = app
        self.dictation = dictation
        self.recorder = recorder
        self.detector = detector
        self.reader = reader
        self.underlines = underlines
        self.selection = selection
        notes = NoteController(library: recorder.library)
        arrangement = PerchArrangement(json: UserDefaults.standard.string(forKey: "perchArrangement"))
        presence = PerchPresence(rawValue: UserDefaults.standard.string(forKey: "perchPresence") ?? "") ?? .full
        position = PerchPosition(rawValue: UserDefaults.standard.string(forKey: "perchPosition") ?? "") ?? .centre
        // On unless it has been switched off: the approved design tucks the perch away in full screen.
        hideInFullScreen = UserDefaults.standard.object(forKey: "perchHideInFullScreen") as? Bool ?? true
        bodyHeights = (UserDefaults.standard.dictionary(forKey: "perchBodyHeights") as? [String: Double]) ?? [:]
        Self.shared = self
        // A test copy run beside the real Chirp must not answer its shortcuts.
        if LinkHandler.noGlobalShortcuts { KeyboardShortcuts.isEnabled = false }
        // In every Space, full-screen ones included: there it tucks under the edge when the setting says so.
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        selection.onShown = { [weak self] shown in self?.selectionChanged(shown) }
        selection.onSaved = { [weak self] line in self?.say(line) }
        // "Say it as" has a field to type in: the perch takes the keyboard while it is open, and Escape closes it.
        reader.onSayItAs = { [weak self] shown in
            guard let self else { return }
            if shown {
                self.panel.makeKey()
                if self.escapeMonitor == nil {
                    self.escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                        guard let self, self.reader.sayItAs != nil, event.keyCode == 53 else { return event }
                        self.reader.closeSayItAs()
                        return nil
                    }
                }
            } else {
                self.giveKeyboardBack()
            }
        }
        selection.releaseKeyboard = { [weak self] in self?.giveKeyboardBack() }
        underlines.onPartly = { [weak self] fixed, left in
            self?.say("Fixed \(fixed) of \(fixed + left)", action: ("Show the rest", { self?.showFixes = true }))
        }
        underlines.onRefused = { [weak self] app, fix in
            // It says what happened and offers the next step: the fix, to paste in by hand.
            self?.say("\(app) did not take that fix", error: true, action: fix.map { words in
                ("Copy it", {
                    TextInserter.copy(words)
                    self?.say("Copied")
                })
            })
        }
        PerchStyle.actionCount = arrangement.shown(Features.shared.set).bar.count
        notes.dictation = dictation
        notes.onOpen = { [weak self] in self?.noteOpened() }
        notes.onClose = { [weak self] saved, announce in self?.noteClosed(saved, announce: announce) }
        Features.shared.whenChanged { [weak self] old, new in
            guard let self else { return }
            PerchStyle.actionCount = self.arrangement.shown(new).bar.count
            PerchStyle.extendedCount = self.extendedOpen ? self.arrangement.shown(new).extended.count : -1
            // What a switched-off feature had open on the perch is put away.
            self.hovering = false
            self.hoverAnchor = nil
            if !new.isOn(.write) {
                self.showFixes = false
                self.selection.close()
            }
            if let doc = self.dropped {
                let summary = doc.summarizing || doc.summary != nil
                if summary ? !new.isOn(.summarize) : new.dropOffers(isFile: doc.url != nil).isEmpty { self.dropped = nil }
            }
            if !new.isOn(.meetings) { self.finished = nil }
            if !new.records { self.showMeetingNotes = false }
            // Notes switched off: an open note is saved and put away.
            if !new.isOn(.notes), self.notes.isOpen { self.notes.close() }
            self.place()
        }
        KeyboardShortcuts.onKeyUp(for: .openLibrary) { AppDelegate.showMain() }
        KeyboardShortcuts.onKeyUp(for: .recordMeeting) { [weak self] in self?.recordMeeting() }
        // Right ⌥ N: a note in the perch. It closes it again, saved, when one is open.
        KeyboardShortcuts.onKeyUp(for: .recordNote) { [weak self] in self?.note() }
        KeyboardShortcuts.onKeyUp(for: .summarize) { [weak self] in self?.summarizeHere() }
        // Right ⌥ I does what Fix on the perch does: the list of fixes, or the rephrase card when there are none.
        KeyboardShortcuts.onKeyUp(for: .writePanel) { [weak self] in self?.fix() }
        // Any Chirp shortcut brings a hidden or tucked perch back. These sit beside each shortcut's own handler.
        for name in Self.everyShortcut {
            KeyboardShortcuts.onKeyDown(for: name) { [weak self] in self?.shortcutUsed() }
        }

        let host = PerchHostingView(rootView: PerchView(perch: self))
        // The bird's own menu on the bird; anywhere else on the bar, the … menu with Customize Perch….
        // Not over a note being written, where a right click is the editor's own.
        host.menuAt = { [weak self] point in
            guard let self else { return nil }
            if let bird = self.birdMenu(at: point) { return bird }
            guard self.barFrame.insetBy(dx: -4, dy: -4).contains(point), self.bar == .actions else { return nil }
            return self.perchMenu()
        }
        panel.contentView = host
        place()
        panel.orderFrontRegardless()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        // The pointer is followed as it moves, not only on the timer: macOS slows the timers of an app
        // that is not in front, and the perch has to answer the moment the pointer reaches it.
        // Both monitors call back on the main thread, so the pointer is followed there and then.
        let moved: (NSEvent) -> Void = { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // A perch that has been picked up follows the pointer from here too, so it keeps moving
                // if the view the drag began on is replaced under it.
                if self.dragging, !self.heldByLink { self.dragMoved() }
                self.trackPointer()
            }
        }
        mouseMonitors = [
            // Escape closes a document's card even while another app has the keyboard (the card does not
            // take it). The key still reaches that app, which is harmless.
            LinkHandler.noGlobalShortcuts ? nil : NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard event.keyCode == 53 else { return }
                MainActor.assumeIsolated { _ = self?.escape() }
            },
            // The same key while the perch itself has the keyboard (typing notes during a recording).
            // The rephrase panel and a keyboard review take Escape first, in their own monitors.
            NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard event.keyCode == 53, let self, event.window === self.panel else { return event }
                return self.escape() ? nil : event
            },
            NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: moved),
            NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { event in
                moved(event)
                return event
            },
        ].compactMap { $0 }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.place() } }
        // A full-screen app coming or going is noticed at once, not only at the next look.
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.lookForFullScreen() }
            }
        }

        LinkHandler.commands["perch"] = { [weak self] q in
            guard let self else { return }
            if let p = q["presence"].flatMap(PerchPresence.init(rawValue:)) { self.presence = p }
            // "point=3" opens the taller bar as if the pointer were resting on the fourth action.
            if let item = q["point"].flatMap({ Int($0) }), self.content == nil {
                self.debugPoint(at: item)
                self.debugHover = true
            }
            if let h = q["hover"] { self.debugHover = h == "1" ? true : h == "0" ? false : nil }
            if let n = q["notes"] { self.showMeetingNotes = n == "1" }
            if let s = q["spot"].flatMap(PerchSpot.init(stored:)) { self.setSpot(s) }
            if let f = q["fullscreen"] {
                self.debugFullScreen = f == "1" ? true : f == "0" ? false : nil
                self.lookForFullScreen()
            }
            if let t = q["tuck"] { self.hideInFullScreen = t == "1" }
            if let d = q["drag"] {
                // "x,y" as fractions of the screen holds the perch there as if it were being dragged; "end" lets go.
                let parts = d.split(separator: ",").compactMap { Double($0) }
                if parts.count == 2 { self.debugDrag(toFraction: CGPoint(x: parts[0], y: parts[1])) } else { self.dragEnded() }
            }
            if let text = q["say"] {
                self.say(text, error: q["error"] == "1", action: q["action"].map { title in (title, {}) })
            }
            if let h = q["height"], let kind = self.content, let value = Double(h) { self.setBodyHeight(value, for: kind) }
            if let b = q["bar"] {
                let bars: [String: PerchBar] = ["dictating": .dictating, "working": .working, "meeting": .meeting, "reading": .reading, "preparing": .preparing]
                self.debugBar = bars[b]
            }
            // Puts a summary on the open document without running the language model.
            if let summary = q["summary"], self.dropped != nil {
                self.dropped?.summarizing = false
                self.dropped?.summary = summary
            }
            if q["finished"] == "1" {
                // The newest recording that has notes, as the card that opens when notes are ready.
                self.dropped = nil
                self.finished = ((try? self.recorder.library.items(kinds: [.meeting, .voiceNote])) ?? []).first { !$0.summary.isEmpty }
            }
            if let open = q["extended"] {
                self.extendedOpen = open == "1"
                self.extendedPinned = open == "1"
            }
            switch q["do"] {
            case "note": self.note()
            case "more-button": self.pressMore()
            case "dictate": self.dictate()
            case "record": self.record()
            case "record-meeting": self.recordMeeting()
            // The More menu's rows, built without opening the menu (`state` has `perch.more`).
            case "more-menu":
                self.debugMenuOnly = true
                self.showMoreMenu()
                self.debugMenuOnly = false
            case "read": self.read()
            case "fix": self.fix()
            case "summarize": self.summarizeHere()
            case "escape": _ = self.escape()
            case "more": self.expandNotice()
            case "hide-hour": self.hideForAnHour()
            case "hide-shortcut": self.hideUntilShortcut()
            case "shortcut": self.shortcutUsed()
            case "hide-work": self.workHidden = true
            case "tall": if let kind = self.content { self.toggleTall(kind) }
            case "review": self.reviewWithKeyboard()
            default: break
            }
        }
        LinkHandler.commands["drop"] = { [weak self] q in if let p = q["path"] { self?.add(URL(fileURLWithPath: p)) } }
        // Customize Perch without the sheet: `perch-arrange?put=library&in=bar&at=0`, `remove=summarize`,
        // `default=1`, and `customize=1` (or 0) to open the sheet. `state` has `perch.arrangement`.
        LinkHandler.commands["perch-arrange"] = { [weak self] q in
            guard let self else { return }
            if let name = q["put"], let action = PerchAction(rawValue: name) {
                self.arrangement.put(action, in: q["in"] == "extended" ? .extended : .bar, at: Int(q["at"] ?? "") ?? 99)
            }
            if let name = q["remove"], let action = PerchAction(rawValue: name) { self.arrangement.remove(action) }
            if q["default"] == "1" { self.arrangement = .standard }
            if let c = q["customize"] { c == "1" ? self.openCustomize() : (self.customizing = false) }
        }
        watchFileDrags()
        // With `page`, a file's text stands in for a page read off the screen (a test copy cannot read other apps).
        LinkHandler.commands["summarize-here"] = { [weak self] q in
            if let text = q["page"].flatMap({ try? String(contentsOfFile: $0, encoding: .utf8) }) {
                // With `subject`, as if the page were a message read from Mail.
                self?.summarize(gathered: ReadController.Gathered(text: text, how: "page", subject: q["subject"]), from: q["subject"] == nil ? "Safari" : "Mail")
            } else {
                self?.summarizeHere()
            }
        }
        LinkHandler.commands["drop-do"] = { [weak self] q in
            switch q["what"] {
            case "read": self?.readDropped()
            case "summarize": self?.summarizeDropped()
            case "record": self?.recordWithDropped()
            case "keep": self?.keepDroppedInLibrary()
            case "attach": self?.attachDropped()
            default: self?.dropped = nil
            }
        }
        LinkHandler.stateProviders["drop"] = { [weak self] in
            guard let doc = self?.dropped else { return ["open": false] }
            return ["open": true, "title": doc.imported.title, "minutes": doc.minutes, "summary": doc.summary ?? "",
                    "summarizing": doc.summarizing, "saved": doc.saved != nil,
                    "draft": doc.summarizing ? (self?.reader.summaryDraft ?? "") : "",
                    "progress": self?.reader.summaryProgress.map { "\($0.part) of \($0.of)" } ?? ""] as [String: Any]
        }
        // The More menu, without opening it: `more-menu?app=com.apple.mail&name=Mail&selected=some%20words`
        // builds it as it would be over that app with those words selected, and `state` has `more` (each
        // row, "(off)" after a greyed one, and the style submenu's rows with a tick on the chosen one).
        // `&style=formal` picks from the submenu; `&do=snippet` presses Save as a Snippet….
        LinkHandler.commands["more-menu"] = { [weak self] q in
            guard let self else { return }
            let front = q["app"].map { (id: $0, name: q["name"] ?? $0) }
            func rows(_ menu: NSMenu) -> [String] {
                menu.items.map { item in
                    if item.isSeparatorItem { return "-" }
                    return (item.state == .on ? "✓ " : "") + item.title + (item.action == nil && item.submenu == nil ? " (off)" : "")
                }
            }
            var menu = self.moreMenu(front: front, selected: q["selected"])
            if let style = q["style"], let sub = menu.items.first(where: { $0.submenu != nil })?.submenu,
                let item = sub.items.first(where: { $0.title.lowercased() == style }) as? ClosureMenuItem
            {
                item.press()
                menu = self.moreMenu(front: front, selected: q["selected"])
            }
            if q["do"] == "snippet", let words = q["selected"] { self.selection.askCue(for: words, alone: true) }
            self.moreSeen = ["rows": rows(menu), "style": menu.items.first(where: { $0.submenu != nil })?.submenu.map(rows) ?? []]
        }
        LinkHandler.stateProviders["more"] = { [weak self] in self?.moreSeen ?? [:] }
        LinkHandler.stateProviders["perch"] = { [weak self] in
            guard let self else { return [:] }
            return ["presence": self.presence.rawValue, "mode": "\(self.mode)", "notice": self.notice?.text ?? "",
                    "visible": self.panel.isVisible, "hovering": self.hovering, "ticks": self.ticks,
                    "rect": NSStringFromRect(self.drawnRect), "pointer": NSStringFromPoint(NSEvent.mouseLocation),
                    "clickThrough": self.panel.ignoresMouseEvents,
                    "spot": self.spot.stored, "content": self.content?.rawValue ?? "", "upright": self.upright,
                    "tucked": self.tucked, "fullScreen": self.frontFullScreen, "dragging": self.dragging,
                    "hidden": self.hiddenNow, "key": self.panel.isKeyWindow, "more": self.moreMenuTitles,
                    "waiting": self.waitingLine ?? "", "working": self.workingLine, "canStopNotes": self.canStopNotes,
                    "bubble": NSStringFromRect(self.bubbleFrame), "bubbleExpanded": self.noticeExpanded,
                    "actions": self.shownActions.bar.map(\.rawValue), "extendedActions": self.shownActions.extended.map(\.rawValue),
                    "extended": self.extendedOpen, "extendedPinned": self.extendedPinned, "customizing": self.customizing, "arrangement": self.arrangement.json,
                    "bar": NSStringFromRect(self.barFrame), "screen": NSStringFromRect(self.panel.frame)] as [String: Any]
        }
        // Only the perch, as it is on screen, with a little of what is around it.
        LinkHandler.commands["perch-shot"] = { [weak self] q in
            guard let self, let path = q["path"] else { return }
            self.photograph(to: path, margin: Double(q["margin"] ?? "") ?? 24)
        }
    }

    /// Every shortcut Chirp has. Using any of them brings a hidden or tucked perch back.
    private static let everyShortcut: [KeyboardShortcuts.Name] = [
        .dictate, .pasteLast, .readSelection, .writePanel, .rephrase, .fixSentence,
        .recordNote, .recordMeeting, .summarize, .openLibrary,
    ]

    /// Writes a picture of the drawn perch alone, cut out of the panel as it is on screen.
    private func photograph(to path: String, margin: Double) {
        guard let image = LinkHandler.windowImage(panel.windowNumber, options: (1 << 0) | (1 << 3)) else { return }
        let scale = CGFloat(image.width) / max(panel.frame.width, 1)
        let area = (dragging ? CGRect(origin: .zero, size: panel.frame.size) : surfaceFrame.insetBy(dx: -margin, dy: -margin))
            .intersection(CGRect(origin: .zero, size: panel.frame.size))
        let cut = CGRect(x: area.minX * scale, y: area.minY * scale, width: area.width * scale, height: area.height * scale)
        guard let cropped = image.cropping(to: cut) else { return }
        try? NSBitmapImageRep(cgImage: cropped).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    /// Escape: puts away the first thing that is open. Returns false when nothing was.
    @discardableResult
    func escape() -> Bool {
        if notice != nil {
            dismissNotice()
        } else if notes.isOpen {
            notes.close()
        } else if selection.shown {
            selection.close()
        } else if showFixes {
            showFixes = false
        } else if finished != nil {
            finished = nil
        } else if dropped != nil {
            dropped = nil
        } else if showMeetingNotes {
            showMeetingNotes = false
            handKeyboardBack()
        } else if hovering {
            hovering = false
            insideSince = nil
        } else {
            return false
        }
        return true
    }

    /// Set by a test link to hold the perch open or closed whatever the pointer is doing.
    @ObservationIgnored private var debugHover: Bool?
    /// The monitors that follow the pointer, in other apps and in Chirp's own windows. Kept for the app's life.
    private var mouseMonitors: [Any] = []
    /// How many times `tick` has run; test links read it to see that the timer is alive.
    private var ticks = 0

    // MARK: What to show

    /// The one thing the perch is busy with. `rest` means nothing is happening.
    enum Mode: Equatable { case dictating, working, meeting, finishing, reading, rest }

    /// What the bar shows now. The order is the priority: dictation wins over a recording, a recording
    /// over reading aloud, and so on down to rest. What the bird has to say (a status, a call offer)
    /// is not part of it: that is a bubble beside the perch, which stays as it is.
    var mode: Mode {
        let live = liveMode
        // Work put out of sight with its × carries on; the bar shows the actions until it is done.
        if workHidden, live == .working || live == .finishing {
            if reader.isPlaying || reader.isPreparing || (reader.isReadingSelection && reader.item != nil && !heldForSummary) || reader.sayItAs?.place == .perch { return .reading }
            return .rest
        }
        return live
    }

    /// What Chirp is really busy with, whether or not the bar is showing it.
    var liveMode: Mode {
        if dictation.phase == .recording { return .dictating }
        if dictation.phase != .idle { return .working }
        if recorder.phase == .recording { return .meeting }
        if case .finishing = recorder.phase { return .finishing }
        // A meeting's notes being written, or a job waiting its turn behind another.
        if recorder.writingNotesFor != nil || Jobs.shared.firstWaiting != nil { return .working }
        // Reading is paused while "Say it as" is open on the perch: the reading bar and the question stay.
        if reader.isPlaying || reader.isPreparing || (reader.isReadingSelection && reader.item != nil && !heldForSummary) || reader.sayItAs?.place == .perch { return .reading }
        return .rest
    }

    /// What the bird is saying in its bubble, if anything. A status comes first; a call offer waits
    /// behind it and is shown again once the status has gone, for as long as the offer stands.
    var saying: Saying? {
        if let notice {
            return Saying(
                id: notice.id.uuidString, lead: nil, text: notice.text, isError: notice.isError,
                buttons: notice.actionTitle.map { [$0] } ?? [], passes: true)
        }
        if let offer = detector.currentOffer {
            return Saying(id: "offer-" + offer.id, lead: offer.title, text: "Take notes?", isError: false, buttons: ["Record", "Not now"], passes: false)
        }
        return nil
    }

    /// One of the bubble's buttons was pressed, counted from the first.
    func pressSayingButton(_ index: Int) {
        if notice != nil {
            runNoticeAction()
        } else if detector.currentOffer != nil {
            // The same two answers the offer has always had.
            if index == 0 { detector.acceptOffer() } else { detector.declineOffer() }
        }
    }

    /// How long a line stays on the bar by itself. It also goes on a click, on Escape and with its ×.
    static let noticeSeconds = 3.0

    /// Shows one line on the bar, with an optional button. It never holds the bar: it goes after three
    /// seconds at most, or sooner on a click, Escape or its ×. Something that went wrong (`error`) stays
    /// until it is dismissed.
    func say(_ text: String, seconds: Double = PerchController.noticeSeconds, error: Bool = false, action: (title: String, run: () -> Void)? = nil) {
        notice = Notice(text: text, actionTitle: action?.title, isError: error)
        noticeAction = action?.run
        // A new one takes the bubble over in place and starts its own time.
        noticeExpanded = false
        noticeAge = 0
        noticeLife = error ? .infinity : min(seconds, Self.noticeSeconds)
        // A tucked or hidden perch comes back to say it.
        revealUntil = max(revealUntil, Date().addingTimeInterval(Self.noticeSeconds + 1))
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
            .announcement: text, .priority: NSAccessibilityPriorityLevel.medium.rawValue,
        ])
    }

    /// Puts the bubble away.
    func dismissNotice() {
        notice = nil
        noticeAction = nil
        noticeExpanded = false
        bubbleFrame = .zero
    }

    /// "More" on a long status: the bubble grows to show all of it, and stays until it is dismissed.
    func expandNotice() {
        noticeExpanded = true
    }

    /// Counts the bubble's time on screen, a tenth of a second at a time. The count waits while the
    /// pointer is on the bubble, and stops for good once all of a long status has been asked for.
    private func ageNotice() {
        guard notice != nil, !noticeExpanded, noticeLife.isFinite else { return }
        if let pointer, bubbleFrame.insetBy(dx: -4, dy: -4).contains(pointer) { return }
        noticeAge += 0.1
        if noticeAge >= noticeLife { dismissNotice() }
    }

    /// The button on the notice was pressed: put the notice away and do what it offers. The notice goes
    /// first, so one the action itself shows is not wiped.
    func runNoticeAction() {
        let run = noticeAction
        notice = nil
        noticeAction = nil
        run?()
    }

    // MARK: Actions on the bar

    /// Starts dictation that keeps listening without a key held, or finishes the one in progress.
    func dictate() {
        guard Features.on(.dictate) else { return }
        if dictation.phase == .recording { dictation.finish() } else { dictation.startHandsFree() }
    }

    /// "Record a voice note" (in a note's foot row, the Notes page and the menu bar): a voice note, in one
    /// press and with no question. Pressed while a recording runs (of either kind), it stops it.
    func record() {
        // A recording under way can always be stopped; a new one starts only while Notes is on.
        guard Features.on(.notes) || recorder.phase == .recording else { return }
        if recorder.phase == .recording {
            recorder.stop()
        } else {
            // Talking at length is a voice note of its own: an open note is saved and put away first.
            if notes.isOpen { notes.close(announce: false) }
            recorder.start(.voiceNote)
        }
    }

    /// Note on the perch, in the menu bar and on Home, and right ⌥ N: the perch grows into a note with
    /// the keyboard in it, listening (Dictate on): what is said goes in as it is heard, and typing takes
    /// over. Pressed with a note open, it stops listening, waits for the last words, and closes it, saved.
    func note() {
        guard Features.on(.notes) else { return }
        // A recording has the microphone: the note is for typing then.
        if notes.isOpen { notes.close() } else { notes.openNew(listen: recorder.phase != .recording) }
    }

    /// "Record a Meeting" in More and the menu bar, and its shortcut: for a meeting in the room, or one
    /// Chirp did not notice. With an offer showing it takes the offer up, so the call's name and app go with it.
    func recordMeeting() {
        guard Features.on(.meetings) || recorder.phase == .recording else { return }
        if recorder.phase == .recording {
            recorder.stop()
        } else if detector.currentOffer != nil {
            detector.acceptOffer()
        } else {
            recorder.start(.meeting)
        }
    }

    /// TESTING: the More menu's rows as they were last built, and whether to build them without opening the menu.
    var moreMenuTitles: [String] = []
    var debugMenuOnly = false

    /// Reads aloud what is selected in the app in front.
    func read() {
        guard Features.on(.read) else { return }
        Task { await reader.readSelection() }
    }

    /// With problems underlined in the app in front, shows them all; otherwise opens the rephrase panel on the selection.
    func fix() {
        guard Features.on(.write) else { return }
        if showFixes {
            showFixes = false
        } else if !underlines.shown.isEmpty || underlines.off != nil {
            showFixes = true
        } else {
            rephrase()
        }
    }

    /// Opens the suggestions with the keyboard in them: the arrows move, Return applies the fix, Delete
    /// dismisses it and Escape closes, so the whole list can be worked through without the mouse.
    func reviewWithKeyboard() {
        guard Features.on(.write) else { return }
        if fixCursor != nil { return showFixes = false }
        guard mode == .rest, !underlines.shown.isEmpty else {
            return say(underlines.status.hasPrefix("Off") ? "Writing checks are off here" : "Nothing to fix here", seconds: 3)
        }
        showFixes = true
        fixCursor = 0
        // The list keeps what it is showing while the keyboard is in Chirp's bar and not in the text.
        underlines.reviewing = true
        panel.makeKey()
        reviewMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.fixCursor != nil else { return event }
            return self.reviewKey(event) ? nil : event
        }
    }

    /// Handles one key press during a keyboard review. Returns false for keys it has no use for, so
    /// they go on to wherever they were headed.
    private func reviewKey(_ event: NSEvent) -> Bool {
        // Only the rows the list draws can be reached.
        let issues = Array(underlines.shown.prefix(Self.fixRowLimit))
        guard let at = fixCursor, !issues.isEmpty else {
            showFixes = false
            return true
        }
        let index = min(at, issues.count - 1)
        // ⌘Return fixes everything, as the foot row says.
        if event.keyCode == 36 || event.keyCode == 76, event.modifierFlags.contains(.command) {
            underlines.fixAll()
            return true
        }
        switch event.keyCode {
        case 125, 48: fixCursor = min(index + 1, issues.count - 1)  // down, tab
        case 126: fixCursor = max(index - 1, 0)  // up
        case 36, 76:  // return, enter
            if let fix = issues[index].suggestions.first { underlines.apply(fix, to: issues[index]) } else { fixCursor = min(index + 1, issues.count - 1) }
            settleCursor()
        case 51, 117:  // delete
            underlines.dismiss(issues[index])
            settleCursor()
        case 53: showFixes = false  // escape
        default: return false
        }
        return true
    }

    /// After a suggestion leaves the list, the cursor stays on the row that took its place.
    private func settleCursor() {
        let count = min(underlines.shown.count, Self.fixRowLimit)
        if count == 0 { showFixes = false } else if let at = fixCursor { fixCursor = min(at, count - 1) }
    }

    /// Ends a keyboard review: stops taking keys and lets the suggestions follow the text again.
    private func endKeyboardReview() {
        guard fixCursor != nil || reviewMonitor != nil else { return }
        fixCursor = nil
        if let reviewMonitor { NSEvent.removeMonitor(reviewMonitor) }
        reviewMonitor = nil
        underlines.reviewing = false
        handKeyboardBack()
    }

    /// Hands the keyboard back to the app the user was typing in. The panel is taken off screen and
    /// put straight back, which is what makes macOS give up its key window.
    private func handKeyboardBack() {
        if panel.isKeyWindow {
            panel.orderOut(nil)
            panel.orderFrontRegardless()
        }
    }

    /// The rephrase card opened or closed. While it is open the perch holds the keyboard, so Escape closes
    /// it; when it goes, the keyboard returns to the app the user was typing in.
    private func selectionChanged(_ shown: Bool) {
        if shown {
            showFixes = false
            // A summary that is being written, or has been, is kept behind the card and comes back when
            // the card closes. It used to be thrown away, and text from the screen is kept nowhere else.
            if let doc = dropped, !doc.summarizing, doc.summary == nil { dropped = nil }
            panel.makeKey()
            if escapeMonitor == nil {
                escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    guard let self, self.selection.shown, event.keyCode == 53 else { return event }
                    self.selection.close()
                    return nil
                }
            }
        } else {
            giveKeyboardBack()
        }
    }

    /// Stops watching for Escape and returns the keyboard to the app the user was in.
    func giveKeyboardBack() {
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
        handKeyboardBack()
    }

    /// Opens the rephrase card on the text selected in the app in front.
    func rephrase() {
        guard Features.on(.write) else { return }
        showFixes = false
        Task { await selection.openForSelection() }
    }

    func openLibrary() { AppDelegate.showMain() }

    /// Takes a file dropped on the perch or the Dock icon: audio is transcribed, a document dropped during a
    /// recording is given to that recording, and anything else joins the reading list.
    func add(_ url: URL) {
        // Sound is transcribed by Record; a document needs something switched on that can be done with it.
        guard Features.shared.set.takesDrop(audio: url.isAudioOrVideo) else {
            return say(url.isAudioOrVideo ? "Record is switched off" : "Nothing that is switched on can open this", seconds: 4,
                       action: ("Settings", { [weak self] in
                           self?.app.settingsTab = .general
                           self?.openSettings()
                       }))
        }
        if url.isAudioOrVideo {
            // One thing at a time: a file cannot be transcribed while Chirp is listening or writing.
            guard dictation.phase == .idle else { return say(Self.busyLine, seconds: 4) }
            say("Transcribing \(url.lastPathComponent)", seconds: 5)
            Task {
                // Only said when a transcript was really saved (a silent or unreadable file saves nothing).
                guard await dictation.transcribe(file: url) else {
                    return say("Chirp could not transcribe \(url.lastPathComponent)", error: true)
                }
                say("\(url.lastPathComponent) is transcribed", seconds: 8, action: ("Open", {
                    self.app.section = .documents
                    AppDelegate.showMain()
                }))
            }
        } else if liveMode != .rest, liveMode != .reading, liveMode != .meeting {
            // The perch is taken up with something else, which would put the card away at once.
            say(Self.busyLine, seconds: 4)
        } else {
            // A document: the perch opens to show what it is and what can be done with it. Dropped while
            // recording, "Attach to this recording" is the first of those; nothing is attached by itself.
            do {
                showMeetingNotes = false
                let imported = try DocumentImporter.importFile(url)
                selection.close()
                showFixes = false
                dropped = DroppedDocument(url: url, imported: imported)
                Log.write("perch", "a document was dropped (\(imported.text.count) characters)")
            } catch { app.report(error, doing: "open \(url.lastPathComponent)") }
        }
    }

    /// Said when a file is dropped while Chirp cannot take it.
    private static let busyLine = "Chirp is busy. Drop it again in a moment."
    /// The most suggestions the list draws, and so the furthest the keyboard can go.
    static let fixRowLimit = 200

    // MARK: A dropped document

    /// A document dropped on the perch, and what has been done with it so far.
    struct DroppedDocument {
        /// Tells one card from the next, so a summary that finishes late is not put on a newer card.
        let id = UUID()
        /// The file, when it came as one. Text taken from the screen has none.
        let url: URL?
        let imported: DocumentImporter.Imported
        /// Its place in the Library, once something has needed it kept.
        var saved: SavedItem?
        var summary: String?
        var summarizing = false
        var minutes: Int { max(1, Int((ReadingText.estimatedDuration(imported.text) / 60).rounded())) }
    }

    /// A file being dragged on screen, and whether it is over the perch (`PerchDrop.swift`).
    var fileDrag = FileDrag()
    @ObservationIgnored private var dragWatcher: FileDragWatcher?

    /// Starts noticing files dragged anywhere on screen, and registers the drop's test links.
    func watchFileDrags() {
        if dragWatcher == nil { dragWatcher = FileDragWatcher(perch: self) }
        registerDropDebug()
    }

    /// The document the card above the perch is about; nil when no card is open.
    var dropped: DroppedDocument? {
        didSet {
            // Closed (or replaced) while its summary was being written: the writing stops. The language
            // model is told to stop and is ended five seconds later if it has not (`LanguageSupervisor.run`).
            if let old = oldValue, old.summarizing, dropped?.id != old.id { cancelSummary() }
            // Closed, however that happened: text the reader was only holding for its summary is let go.
            if dropped == nil, oldValue != nil { releaseSummaryText() }
        }
    }

    /// The summary being written for the card, so closing the card can stop it.
    private var summaryTask: Task<Void, Never>?
    /// True from the moment a summary is stopped until its work has wound down (at most a few seconds).
    private var summaryStopping = false

    /// Stops the summary being written for the card.
    private func cancelSummary() {
        guard let task = summaryTask, !summaryStopping else { return }
        summaryStopping = true
        Log.write("summary", "cancelled")
        task.cancel()
    }

    /// Text from the screen that the reader is holding only so it could be summarized. Nobody asked for it
    /// to be read, so the bar stays on the actions while it is there, and it goes when the summary closes.
    private var summaryText: String?

    /// True while the reader's one-off text is there only for a summary and nothing is being read.
    private var heldForSummary: Bool {
        guard let summaryText, let open = reader.item else { return false }
        return open.id == nil && open.body == summaryText && !reader.isPlaying && !reader.isPreparing
    }

    /// Lets go of the text the reader was holding for a summary, once it is no longer needed. A summary
    /// still being written keeps it until it finishes.
    private func releaseSummaryText() {
        guard dropped == nil, !reader.summarizing else { return }
        if heldForSummary { reader.dismiss() }
        summaryText = nil
    }

    /// Opens the document in the reader. A file is kept in the Library (once); text taken from the
    /// screen is only opened for now, and kept if the user asks.
    private func openDropped() -> Bool {
        guard var doc = dropped else { return false }
        // Already in the Library (a file opened before, or the saved document being read): open that
        // one, so its place and its summary stay with it.
        if let saved = doc.saved {
            reader.open(saved)
            return true
        }
        // A dropped file is opened the same way as text from the screen: for now, and kept only if
        // "Keep in Library" is chosen ("Not saved unless you keep it").
        if reader.item?.body != doc.imported.text || reader.item?.id != nil {
            reader.openOnce(doc.imported)
            // Opened for a summary (or to be kept), not to be read. Read aloud takes this back.
            summaryText = doc.imported.text
        }
        doc = dropped ?? doc
        return true
    }

    /// Reads it aloud, from the start. It is not kept unless "Keep in Library" is chosen.
    func readDropped() {
        guard Features.on(.read), openDropped() else { return }
        // Asked to be read: the reading controls are right from here on.
        summaryText = nil
        dropped = nil
        reader.play()
    }

    /// Keeps text that came from the screen in the Library, with its summary.
    func keepDroppedInLibrary() {
        guard dropped != nil, openDropped() else { return }
        dropped?.saved = reader.keepCurrent()
    }

    /// Writes a summary and shows it on the card. The summary is kept with the document.
    func summarizeDropped() {
        guard Features.on(.summarize), let card = dropped?.id, dropped?.summarizing == false else { return }
        // The reader writes one summary at a time. One that was just cancelled is on its way out and is
        // waited for below; it never turns the next one away.
        guard !reader.summarizing || summaryStopping else { return say("Chirp is still writing another summary", seconds: 3) }
        guard openDropped() else { return }
        dropped?.summarizing = true
        let stopping = summaryStopping ? summaryTask : nil
        summaryTask = Task {
            if let stopping {
                await stopping.value
                // Closed again while it waited.
                guard dropped?.id == card else { return }
            }
            summaryStopping = false
            let began = Date()
            await reader.summarize()
            if Task.isCancelled {
                summaryStopping = false
                Log.write("summary", String(format: "stopped %.1f s after it began", Date().timeIntervalSince(began)))
            }
            // The card may have been closed or replaced while the summary was written.
            guard let doc = dropped, doc.id == card else { return releaseSummaryText() }
            dropped?.summarizing = false
            if let id = doc.saved?.id {
                // Kept in the Library: show what was saved there, whatever the reader has open by now.
                dropped?.summary = (try? recorder.library.item(id))?.summary ?? reader.item?.summary
            } else if let open = reader.item, open.id == nil, open.body == doc.imported.text {
                dropped?.summary = open.summary
            }
        }
    }

    /// Copies the summary on the card.
    func copyDroppedSummary() {
        guard let summary = dropped?.summary, !summary.isEmpty else { return }
        RichCopy.copy(markdown: summary)
        say("Copied")
    }

    /// Reads the summary aloud, without keeping it as a document of its own.
    func readDroppedSummary() {
        guard Features.on(.read), let summary = dropped?.summary, !summary.isEmpty else { return }
        dropped = nil
        // Read as plain words: the reader shows and times what it is given, and Markdown marks are neither.
        reader.readOnce(DocumentImporter.Imported(title: "Summary", text: MarkdownLines.plain(summary), source: "Summary"))
    }

    /// Summarizes what the user is looking at: the selection, else the text they are in, else the page.
    func summarizeHere() {
        guard Features.on(.summarize) else { return }
        Task {
            let app = NSWorkspace.shared.frontmostApplication?.localizedName ?? "this app"
            guard let found = await reader.gatherText() else {
                return say("Select some text, or click into what you want summarized", seconds: 4)
            }
            summarize(gathered: found, from: app)
        }
    }

    /// Summarizes text gathered from the app in front (or, for testing, handed in as if it had been).
    func summarize(gathered: ReadController.Gathered, from app: String) {
        guard Features.on(.summarize) else { return }
        var found = gathered
        do {
            // Reading starts at the cursor; a summary is of the whole text the cursor is in.
            if found.how == "from the cursor", let field = found.field?.0, let whole = TextInserter.text(of: field) {
                found.text = whole
            }
            // A page read off the screen comes with the site's menus and links around the article, one line
            // to a block: the summary is of the article, with its headings and lists kept apart.
            // Its ads, cookie notice and sign-up boxes go first, so they are not taken for the article's start.
            if found.how == "page" { found.text = PageText.paragraphs(PageText.article(Boilerplate.strip(found.text))) }
            guard let imported = try? DocumentImporter.importText(found.text, title: nil) else {
                return say("Select some text, or click into what you want summarized", seconds: 4)
            }
            guard TextStats.words(imported.text) >= 40 else {
                return say("That is short enough to read as it is", seconds: 4)
            }
            selection.close()
            showFixes = false
            // How much was taken and how, never the words: a summary of the wrong text shows up here.
            Log.write("summary", "text taken from \(app) (\(found.how)): \(imported.text.count) characters")
            // A web page is kept with its address and its own title; anything else says which app it was in.
            // A message from Mail is named by its subject.
            let title = found.subject.flatMap { MailHeader.title($0) } ?? (found.link != nil && found.how == "page" ? found.pageTitle ?? imported.title : imported.title)
            dropped = DroppedDocument(url: nil, imported: DocumentImporter.Imported(title: title, text: imported.text, source: found.link ?? app))
            summarizeDropped()
        }
    }

    /// Summarizes the document being read aloud.
    func summarizeReading() {
        guard Features.on(.summarize), let item = reader.item else { return }
        reader.pause()
        dropped = DroppedDocument(
            url: nil, imported: DocumentImporter.Imported(title: item.title, text: item.body, source: item.source ?? ""),
            saved: item.id == nil ? nil : item, summary: item.summary.isEmpty ? nil : item.summary)
        if dropped?.summary == nil { summarizeDropped() }
    }

    /// Starts a recording that has the document to draw on for its notes.
    func recordWithDropped() {
        guard Features.on(.meetings), let doc = dropped, let url = doc.url else { return }
        dropped = nil
        // A file to draw on is for a meeting's notes.
        if recorder.phase == .idle { recordMeeting() }
        Task {
            // Recording takes a moment to begin; the document is handed over once it has.
            for _ in 0..<40 where recorder.phase != .recording { try? await Task.sleep(for: .milliseconds(100)) }
            if recorder.attach(url) { say("“\(doc.imported.title)” will help with the notes") } else { say("Chirp could not add \(url.lastPathComponent)", error: true) }
        }
    }

    // MARK: Panel

    /// The drawn part of the perch, in screen coordinates.
    var drawnRect: NSRect {
        let frame = panel.frame
        return NSRect(x: frame.minX + surfaceFrame.minX, y: frame.maxY - surfaceFrame.maxY, width: surfaceFrame.width, height: surfaceFrame.height)
    }

    /// The pointer in the panel's own coordinates (origin top left), while it is on the perch.
    /// Buttons light up from this: the panel never becomes the active window, so they get no hover events.
    private(set) var pointer: CGPoint?
    /// When the pointer left the perch, so closing can wait a moment.
    @ObservationIgnored private var outsideSince: Date?
    /// When the pointer arrived on the perch, so opening can wait for it to settle.
    @ObservationIgnored private var insideSince: Date?

    /// How long the pointer rests on the perch before it opens, and how long after it leaves before it closes.
    static let openAfter = 0.3
    static let closeAfter = 0.1

    /// Works out where the pointer is against the drawn perch: which button it is over, whether the
    /// perch should open, and whether clicks land on the perch or pass through to the app underneath.
    private func trackPointer() {
        let mouse = NSEvent.mouseLocation
        // The button came up without the drag being told: let go where it is.
        if dragging, !heldByLink, NSEvent.pressedMouseButtons & 1 == 0 { dragEnded() }
        // A little slack around the edge, so the pointer does not fall off between the perch and a button.
        // The part of a tucked perch that is off the screen does not count.
        let spot = CGPoint(x: mouse.x - panel.frame.minX, y: panel.frame.maxY - mouse.y)
        let inside = dragging || (panel.isVisible && drawnRect.insetBy(dx: -6, dy: -6).intersection(panel.frame).contains(mouse))
        // The bubble is a piece of its own: clicks land on it, but resting on it does not open the bar.
        let onBubble = panel.isVisible && saying != nil && bubbleFrame.insetBy(dx: -4, dy: -4).contains(spot)
        let at = inside || onBubble ? spot : nil
        if at != pointer { pointer = at }
        // Opening waits for the pointer to rest, so the icons on the bar can be clicked on the way past;
        // closing waits a moment too, so brushing the edge does not make it flicker.
        if inside { outsideSince = nil } else if outsideSince == nil { outsideSince = Date() }
        // The bird is the handle for dragging and for its menu: resting on it does not open the bar.
        // (With only the bird showing there is nothing else to point at, so there it does.)
        let along = inside ? at.map { upright ? $0.y - barFrame.minY : $0.x - barFrame.minX } : nil
        let plainBar = bar == .actions && content == nil && !tucked
        let onBird = plainBar && (along.map { $0 < PerchStyle.birdEnd(upright: upright) } ?? false)
        if !inside || onBird { insideSince = nil } else if insideSince == nil { insideSince = Date() }
        let settled = insideSince.map { Date().timeIntervalSince($0) >= Self.openAfter } ?? false
        let lingering = outsideSince.map { Date().timeIntervalSince($0) < Self.closeAfter } ?? true
        // A tucked perch comes out when the pointer rests on its edge, and goes back a moment after it leaves.
        if settled { revealed = true } else if !inside, let outsideSince, Date().timeIntervalSince(outsideSince) > 0.8 { revealed = false }
        let hover = debugHover ?? (dragging || tucked ? false : inside ? (hovering || settled) : (hovering && lingering))
        if hover, !hovering, plainBar, let along {
            // About to grow: note which action the pointer is on, so it is still under the pointer afterwards.
            let item = PerchStyle.nearestItem(to: along, upright: upright)
            let start = upright ? barFrame.minY : barFrame.minX
            hoverAnchor = (item, start + PerchStyle.itemCentre(item, tall: false, upright: upright))
        } else if !hover, hovering || hoverAnchor != nil {
            hoverAnchor = nil
        }
        if hover != hovering { hovering = hover }
        // Clicks outside the drawn parts go to whatever is underneath.
        let taking = inside || onBubble
        if panel.ignoresMouseEvents == taking { panel.ignoresMouseEvents = !taking }
    }

    /// Ten times a second: shows or hides the panel, closes cards whose reason has gone, and says once
    /// when a recording's notes are ready.
    private func tick() {
        ticks += 1
        trackPointer()

        if ticks % 5 == 0 { lookForFullScreen() }
        // Something started from the taller bar (a click, a shortcut): pointing starts afresh once it is
        // over, so the bar is never opened again around where the pointer used to be.
        if hovering || hoverAnchor != nil, mode != .rest, debugHover == nil {
            hovering = false
            hoverAnchor = nil
            insideSince = nil
        }
        if let until = hiddenUntil, Date() >= until { hiddenUntil = nil }
        // Hidden work comes back into view with the next piece of work.
        if workHidden, liveMode != .working, liveMode != .finishing { workHidden = false }
        // Out of sight at rest when asked to be; anything Chirp is doing or has to show brings it back.
        ageNotice()
        let wanted = !((presence == .hidden || hiddenNow) && mode == .rest && (content == nil || content == .tiles) && saying == nil)
        if wanted != panel.isVisible { wanted ? panel.orderFrontRegardless() : panel.orderOut(nil) }
        // Under the edge while a full-screen app is in front, unless there is something to see or do.
        let tuck = hideInFullScreen && frontFullScreen && mode == .rest && content == nil && !dragging
            && saying == nil && !revealed && Date() >= revealUntil
        if tuck != tucked { tucked = tuck }

        if recorder.phase != .recording, showMeetingNotes { showMeetingNotes = false }
        // The keyboard goes back to the app in front once nothing on the perch needs it.
        if panel.isKeyWindow, !selection.shown, fixCursor == nil, content != .meetingNotes, content != .note { handKeyboardBack() }
        // The extended area closes when a job starts, and when the pointer leaves the perch unless it was
        // clicked open.
        // The extended area is shown while the user has it open, at rest only (the chevron alone opens and
        // closes it; nothing else does).
        let showExtended = extendedPinned && mode == .rest && !notes.isOpen
        if extendedOpen != showExtended { extendedOpen = showExtended }
        // The list goes away with the last suggestion, or when something else needs the perch.
        if showFixes, (underlines.shown.isEmpty && underlines.off == nil) || mode != .rest { showFixes = false }
        if selection.shown, mode != .rest { selection.close() }
        // A notice passes; the card stays for when it has gone.
        if dropped != nil, mode != .rest, mode != .reading, mode != .meeting { dropped = nil }
        // Say once when a recording's notes are ready.
        let writing = recorder.writingNotesFor
        // Not when they were stopped part-way: there is nothing new to show.
        if let was = wasWritingNotes, writing == nil, recorder.notesStoppedFor != was { notesToShow = was }
        wasWritingNotes = writing
        // Shown once the recorder has finished with it (the title is written after the notes), as a card
        // that stays until it is closed: a line that passes in a few seconds is easily missed.
        if let id = notesToShow, recorder.phase == .idle, writing == nil {
            notesToShow = nil
            if let item = try? recorder.library.item(id), !item.summary.isEmpty, mode == .rest {
                dropped = nil
                showFixes = false
                finished = item
            } else {
                say("Your notes are ready", action: ("Open", { AppDelegate.showMain(.record) }))
            }
        }
        // The card makes way when something else needs the perch.
        if finished != nil, mode != .rest { finished = nil }
    }}

/// A clear, borderless panel that floats over other apps and never makes Chirp the active app.
/// It takes the keyboard only when a text field in it is clicked (the meeting notes), or when the perch
/// asks for it (a new note, the rephrase panel, a keyboard review).
final class PerchPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
        ignoresMouseEvents = true
        // Which Spaces it shows in is set by the controller.
    }

    override var canBecomeKey: Bool { true }
}

/// Chirp is never the app in front, so every click on the perch is the first click on an inactive
/// window. Without this the click is swallowed and the buttons do nothing.
class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The perch's own view: a right click is offered to the controller first (the bird's menu).
final class PerchHostingView<Content: View>: FirstClickHostingView<Content> {
    /// Given where the click landed (origin top left), returns the menu to open there, or nil for none.
    var menuAt: ((CGPoint) -> NSMenu?)?

    override func rightMouseDown(with event: NSEvent) {
        let at = convert(event.locationInWindow, from: nil)
        let point = CGPoint(x: at.x, y: isFlipped ? at.y : bounds.height - at.y)
        if let menu = menuAt?(point) {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        } else {
            super.rightMouseDown(with: event)
        }
    }
}
