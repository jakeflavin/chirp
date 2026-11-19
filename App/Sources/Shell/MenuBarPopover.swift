import AppKit
import ChirpCore
import ChirpML
import SwiftUI

// The menu bar item and its popover (Docs/DESIGN.md, section 3). The popover is laid out
// like Control Center so it reads as part of the Mac. Top to bottom: what Chirp is doing with its
// controls, the five actions, the last three captured items, quick settings, then Library / Settings / Quit.
//
// The item is an `NSStatusItem` and the popover a panel of our own, not a window-style `MenuBarExtra`:
//   - A `MenuBarExtra` cannot be opened or closed by code (its button has no action, and it ignores a
//     made-up click), so an action could not close it reliably and it could not be checked by test links.
//   - The panel does not make Chirp the app in front. The app being used stays in front, so Dictate,
//     Read, Fix and Summarize act on it the moment the popover closes.
//   - Pointing: rows light up from the pointer's place, read 30 times a second while the popover is
//     open, so the highlight does not depend on hover events reaching a menu bar window.
//   - Keys: arrows and Tab move, Return and Space press, Escape closes, whether or not the Mac's
//     "Keyboard navigation" setting is on (without it Tab skips buttons).

/// What the popover's first row says Chirp is doing.
enum MenuActivity: String {
    case ready, dictating, writingDown, recording, writingNotes, reading
    /// A job is waiting its turn behind another.
    case waiting
    /// A summary is being written; a file or link is being transcribed.
    case summarizing, transcribing
}

/// The state behind the menu bar item: what Chirp is doing (for the icon and the popover's first row),
/// what is pointed at, where the keyboard is, and what each control does.
@MainActor
@Observable
final class MenuBarModel {
    static var shared: MenuBarModel?
    /// Stored setting: show the time beside the red dot while recording. On unless turned off.
    static let timerKey = "menuBarShowTimer"
    /// Stored: how much of the perch showed before "Show the perch" was switched off, to go back to.
    static let presenceKey = "perchPresenceBeforeHidden"
    /// The popover's width and corner.
    static let width: CGFloat = 340
    static let radius: CGFloat = 18

    let app: AppModel
    let dictation: DictationController
    let recorder: MeetingRecorder
    let reader: ReadController
    let perch: PerchController
    let underlines: UnderlineController

    /// A state put on by a test link, shown without any audio behind it.
    struct Staged {
        var activity: MenuActivity
        var line = ""
        /// A title in place of the activity's own ("Transcribing · 40%").
        var title: String?
        /// The situation the settings area is drawn for; nil for the one the activity gives.
        var situation: MenuSituation?
        var playing = true
        var attention = false
    }
    var staged: Staged?

    // MARK: What Chirp is doing

    var activity: MenuActivity {
        if let staged { return staged.activity }
        if dictation.phase == .recording { return .dictating }
        if dictation.phase != .idle { return .writingDown }
        if recorder.phase == .recording { return .recording }
        if case .finishing = recorder.phase { return .writingNotes }
        if reader.isPlaying || reader.isPreparing || reader.isReadingSelection { return .reading }
        // A document paused from here stays, so it can be carried on from here.
        if let paused = pausedDocument, reader.item?.id == paused { return .reading }
        // A job waiting its turn says so, with Cancel; what it waits behind carries on.
        if Jobs.shared.firstWaiting != nil { return .waiting }
        if recorder.writingNotesFor != nil { return .writingNotes }
        if reader.summarizing || perch.dropped?.summarizing == true { return .summarizing }
        if dictation.importStatus != nil { return .transcribing }
        return .ready
    }

    /// True while nothing is going on and writing checks are looking at a field of the app in front.
    private var checkingWriting: Bool {
        staged == nil && Features.on(.write) && underlines.enabled && frontName != nil && underlinesHere && !underlines.text.isEmpty
            && (frontName == underlines.appName || underlines.appName.isEmpty)
    }

    var title: String {
        if let title = staged?.title { return title }
        return switch activity {
        case .ready: situation == .writing && staged == nil ? "Checking your writing" : "Ready"
        case .dictating, .writingDown: "Dictating"
        case .recording: recorder.kind == .meeting ? "Recording" : "Note"
        case .writingNotes: "Writing notes"
        case .reading: "Reading aloud"
        case .waiting: "Waiting"
        case .summarizing: "Summarizing"
        // How far along goes with the title: "Transcribing · 40%".
        case .transcribing: staged?.title ?? dictation.importStatus.flatMap { LibraryList.fraction(in: $0.line) }.map { "Transcribing · \(Int($0 * 100))%" } ?? "Transcribing"
        }
    }

    /// The line under the title: the time and name of a recording, what is being read. Empty at rest.
    var line: String {
        if let staged { return staged.line }
        switch activity {
        case .ready:
            // Writing in an app: where, and how many suggestions there are. At rest: how to dictate.
            if situation == .writing, let frontName {
                let n = underlines.shown.count
                return "\(frontName) · \(n == 0 ? "no suggestions" : n == 1 ? "1 suggestion" : "\(n) suggestions")"
            }
            return restLine
        // How long it has been listening, and where the words will go: "0:08 · into Mail".
        case .dictating: return dictation.elapsed.clock + (frontName.map { " · into \($0)" } ?? "")
        case .summarizing:
            let what = perch.dropped?.imported.title ?? reader.item?.title ?? ""
            guard let progress = reader.summaryProgress else { return what }
            return what.isEmpty ? "Part \(progress.part) of \(progress.of)" : "Part \(progress.part) of \(progress.of) · \(what)"
        case .transcribing: return dictation.importStatus?.name ?? ""
        case .writingDown: return "Writing it down"
        // What is being recorded, then how long: "Voice note · 2:14".
        case .recording: return "\(recorder.title.isEmpty ? recorder.kind.name : recorder.title) · \(recorder.elapsed.clock)"
        case .writingNotes:
            if case .finishing(let step) = recorder.phase { return step }
            return recorder.writingNotesFor.flatMap { try? recorder.library.item($0) }?.title ?? ""
        case .waiting: return Jobs.shared.waitingDetail ?? ""
        case .reading: return reader.item?.title ?? ""
        }
    }

    /// The line under "Ready": how dictation is started, while Dictate is on.
    var restLine: String {
        guard Features.on(.dictate) else { return "" }
        switch dictation.holdKey {
        case .rightOption: return "Hold right ⌥ to dictate"
        case .rightCommand: return "Hold right ⌘ to dictate"
        case .fn: return "Hold Fn to dictate"
        case .none: return ShortcutLayout.label(.dictate).map { "Press \($0) to dictate" } ?? ""
        }
    }

    /// True while the voice is going (the button then pauses; otherwise it plays).
    var readingAloud: Bool { staged?.playing ?? reader.isPlaying }

    /// What the menu bar item itself shows.
    var icon: MenuIconState {
        if let staged {
            switch staged.activity {
            case .recording: return .recording(staged.line.components(separatedBy: " · ").first ?? "0:00")
            case .dictating: return .dictating
            case .reading: return .reading
            case .writingDown, .writingNotes, .waiting, .summarizing, .transcribing: return .working
            case .ready: return staged.attention ? .attention : .idle
            }
        }
        if recorder.phase == .recording { return .recording(recorder.elapsed.clock) }
        if dictation.phase == .recording { return .dictating }
        if reader.isPlaying { return .reading }
        var working = dictation.phase != .idle || recorder.writingNotesFor != nil || reader.isPreparing || reader.summarizing || Jobs.shared.line.running != nil || dictation.importStatus != nil
        if case .finishing = recorder.phase { working = true }
        if working { return .working }
        if perch.notice?.isError == true || perch.finished != nil || app.banner != nil { return .attention }
        return .idle
    }

    /// While working the bird goes faint and back. This is the faint half.
    private(set) var pulseDim = true
    @ObservationIgnored private var pulse: Timer?

    // MARK: The popover's own state

    /// The control under the pointer, by id.
    private(set) var hovered: String?
    /// The control the keyboard is on. Nil until a key is used, so no ring shows for someone using the pointer.
    private(set) var focused: String?
    /// The newest three captured items, read when the popover opens.
    private(set) var recent: [SavedItem] = []
    /// The item whose text was just copied, for a moment, so its button can show a tick.
    private(set) var copied: Int64?
    /// The microphone in use, by name.
    private(set) var microphone = ""
    /// The app that was in front before the popover opened: its name, and whether underlines are on in it.
    private(set) var frontName: String?
    private(set) var underlinesHere = true
    /// The writing style of that app: its own, or the usual tone.
    private(set) var styleHere = Formality.neutral
    /// True while the popover is on screen.
    private(set) var isOpen = false
    /// What the settings area is about. Chosen when the popover opens, and it stays while it is open, so
    /// no row moves under the pointer.
    private(set) var situation = MenuSituation.idle

    /// Where each control is, in the popover's own space (origin top left).
    @ObservationIgnored var frames: [String: CGRect] = [:]
    /// The menu bar item and the panel the popover is shown in.
    @ObservationIgnored private(set) var host: MenuBarHost?
    @ObservationIgnored private var pointer: Timer?
    @ObservationIgnored private var keys: Any?
    /// Set by a test link: the popover stays open whatever is clicked elsewhere, and does not take the
    /// keyboard, so it can be photographed while the Mac is in use.
    @ObservationIgnored private(set) var pinned = false
    /// Set by a test link: draw as with Increase Contrast on.
    var stagedContrast = false
    /// Set by a test link to hold the highlight on one control whatever the pointer is doing.
    @ObservationIgnored private var stagedHover: String?
    /// True while one of the popover's own menus (microphones, voices) is open.
    @ObservationIgnored private(set) var inMenu = false
    /// The last app other than Chirp to come to the front: the one "Underlines in …" is about.
    @ObservationIgnored private var lastApp: NSRunningApplication?
    /// A saved document that was paused from the popover.
    private var pausedDocument: Int64?

    init(app: AppModel, dictation: DictationController, recorder: MeetingRecorder, reader: ReadController, perch: PerchController, underlines: UnderlineController) {
        self.app = app
        self.dictation = dictation
        self.recorder = recorder
        self.reader = reader
        self.perch = perch
        self.underlines = underlines
        // A feature switched on or off while the popover is up: what it lists is read again.
        Features.shared.whenChanged { [weak self] _, _ in
            self?.focused = nil
            self?.refresh()
        }
        Self.shared = self

        note(NSWorkspace.shared.frontmostApplication)
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let activated = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { self?.note(activated) }
        }
        // The pulse: every 0.7 s while working the bird swaps between faint and full. At rest the timer
        // changes nothing, so nothing is redrawn. With Reduce Motion the bird stays faint.
        pulse = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let still = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                if self.icon == .working, !still { self.pulseDim.toggle() } else if !self.pulseDim { self.pulseDim = true }
            }
        }
        keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isOpen, event.window === self.host?.panel else { return event }
            return self.key(event) ? nil : event
        }
        host = MenuBarHost(model: self)
        registerDebug()
    }

    // MARK: Opening and closing

    /// The popover's panel.
    var window: NSWindow? { host?.panel }

    /// Remembers an app that came to the front, when it is one a person works in: not Chirp, and not a
    /// system helper that only put up an alert.
    private func note(_ app: NSRunningApplication?) {
        guard let app, app.processIdentifier != ProcessInfo.processInfo.processIdentifier, app.activationPolicy == .regular else { return }
        lastApp = app
    }

    /// The popover is about to come up: read what it shows afresh, so it opens at its right size.
    func willOpen() {
        focused = nil
        hovered = nil
        note(NSWorkspace.shared.frontmostApplication)
        refresh()
    }

    /// The popover is up: start following the pointer.
    func opened() {
        guard !isOpen else { return }
        isOpen = true
        pointer?.invalidate()
        pointer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.followPointer() }
        }
    }

    /// The popover went away.
    func closed() {
        guard isOpen else { return }
        isOpen = false
        pointer?.invalidate()
        pointer = nil
        hovered = nil
        focused = nil
    }

    /// Reads what the popover shows that can change while it is closed.
    func refresh() {
        // Only what a feature that is switched on saved: the rest is kept, out of sight.
        // Dictations are left out, as on Home: there are dozens a day and they have their own page.
        let kinds = Features.shared.set.shownKinds.filter { $0 != .dictation }
        recent = kinds.isEmpty ? [] : (try? recorder.library.items(kinds: kinds, limit: 3)) ?? []
        let chosen = AudioDevices.preferredUID
        microphone = AudioDevices.inputs().first { $0.uid == chosen }?.name
            ?? AudioDevices.recordingDevice().map(AudioDevices.name(of:)) ?? "None"
        if let app = lastApp, !app.isTerminated, let name = app.localizedName {
            frontName = name
            underlinesHere = (try? self.app.engine.underlinesEnabled(for: WorkContext(bundleID: app.bundleIdentifier, appName: name))) ?? true
            styleHere = (try? self.app.engine.formality(for: WorkContext(bundleID: app.bundleIdentifier, appName: name))) ?? .neutral
        } else {
            frontName = nil
        }
        situation = staged?.situation ?? MenuSituation.pick(
            .init(
                dictating: activity == .dictating || activity == .writingDown, recording: activity == .recording,
                reading: activity == .reading, checkingWriting: checkingWriting),
            features: Features.shared.set)
    }

    /// Closes the popover. The app that was in front never stopped being in front, so the keyboard goes back to it.
    func close() { host?.hide() }

    /// Closes the popover, then runs `action` once the keyboard is back with the app in front: dictation
    /// types into that app, and Read, Fix and Summarize work on what is in it.
    private func leave(then action: @escaping @MainActor () -> Void) {
        close()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            action()
        }
    }

    // MARK: Pointing

    private func followPointer() {
        if let stagedHover { return setHovered(stagedHover) }
        guard let panel = host?.panel, panel.isVisible, let view = panel.contentView else { return }
        var point = view.convert(panel.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        if !view.isFlipped { point.y = view.bounds.height - point.y }
        // The smallest control under the pointer: a row's own buttons win over the row.
        let hit = frames.filter { $0.value.contains(point) }.min { $0.value.width * $0.value.height < $1.value.width * $1.value.height }
        setHovered(hit?.key)
    }

    private func setHovered(_ id: String?) {
        if hovered != id { hovered = id }
    }

    /// True when the pointer or the keyboard is on the row or on one of its own buttons.
    func within(_ row: String) -> Bool {
        [hovered, focused].contains { $0 == row || ($0?.hasPrefix(row + ".") ?? false) }
    }

    // MARK: Keys

    /// The controls that can be used right now, in rows as they are laid out, top to bottom.
    var rows: [[String]] {
        var out: [[String]] = []
        let controls = statusControls
        if !controls.isEmpty { out.append(controls) }
        out.append(MenuTile.shown.filter(canStart).map(\.id))
        if canUse("meeting") { out.append(["meeting"]) }
        for index in recent.indices {
            let row = "recent.\(index)"
            // A row's own buttons are reached with the right arrow once the row is lit.
            out.append(within(row) ? [row, row + ".copy", row + ".read"].filter { $0 == row || canUse($0) } : [row])
        }
        for row in situation.rows {
            switch row {
            // The front app's writing style, changed in place.
            case .style: if frontName != nil { out.append(["style"]) }
            case .underlines: if canUse("underlines") { out.append(["underlines"]) }
            case .microphone: out.append(["mic"])
            case .holdKey: out.append(["holdKey"])
            case .macSound: out.append(["macSound"])
            case .voice: out.append(["voice"])
            case .speed: out.append(["speed"])
            case .citations: out.append(["citations"])
            case .features: out.append(GeneralSettings.featureOrder.map { "feature." + $0.rawValue })
            case .perch: out.append(["perch"])
            case .allSettings: out.append(["settings"])
            }
        }
        out.append(["library", "quit"])
        return out.filter { !$0.isEmpty }
    }

    /// The controls of the first row, for what Chirp is doing now.
    var statusControls: [String] {
        switch activity {
        case .recording, .dictating, .summarizing, .transcribing: ["status.stop"]
        case .reading: ["status.play", "status.stop"]
        case .waiting: ["status.cancel"]
        // Notes being written can be stopped; a recording still being saved cannot.
        case .writingNotes: canStopNotes ? ["status.stop"] : []
        case .ready, .writingDown: []
        }
    }

    /// True while a meeting's notes are being written and have not been stopped yet.
    var canStopNotes: Bool {
        if let staged { return staged.activity == .writingNotes }
        return recorder.phase == .idle && recorder.writingNotesFor != nil && !recorder.stoppingNotes
    }

    /// Acts on a key pressed while the popover is open. Returns false for a key that is not its own.
    func key(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) {
            switch event.charactersIgnoringModifiers {
            case ",": activate("settings")
            case "l": activate("library")
            case "q": activate("quit")
            default: return false
            }
            return true
        }
        switch event.keyCode {
        case 53: close()
        case 48: step(flags.contains(.shift) ? -1 : 1)
        case 125: moveRow(1)
        case 126: moveRow(-1)
        case 124: if focused == "speed" { stepSpeed(1) } else { moveInRow(1) }
        case 123: if focused == "speed" { stepSpeed(-1) } else { moveInRow(-1) }
        case 36, 76, 49: if let focused { activate(focused) }
        default: return false
        }
        return true
    }

    /// Tab: the next control in reading order, round and round.
    private func step(_ by: Int) {
        let all = rows.flatMap { $0 }
        guard !all.isEmpty else { return }
        guard let focused, let at = all.firstIndex(of: focused) else { return self.focused = by > 0 ? all.first : all.last }
        self.focused = all[(at + by + all.count) % all.count]
    }

    /// Up and down: the row above or below, keeping to the same place along it where there is one.
    private func moveRow(_ by: Int) {
        let rows = rows
        guard let focused, let r = rows.firstIndex(where: { $0.contains(focused) }) else { return self.focused = by > 0 ? rows.first?.first : rows.last?.first }
        let target = r + by
        guard rows.indices.contains(target) else { return }
        // A row's own buttons are left behind: the next row is entered at its start.
        let column = focused.hasPrefix("recent.") ? 0 : rows[r].firstIndex(of: focused) ?? 0
        self.focused = rows[target][min(column, rows[target].count - 1)]
    }

    /// Left and right: along the row.
    private func moveInRow(_ by: Int) {
        let rows = rows
        guard let focused, let row = rows.first(where: { $0.contains(focused) }), let at = row.firstIndex(of: focused) else { return step(by) }
        self.focused = row[max(0, min(row.count - 1, at + by))]
    }

    // MARK: What each control does

    /// Whether a control can be used right now. One that cannot is shown dimmed and is skipped by the keys.
    func canUse(_ id: String) -> Bool {
        if let tile = MenuTile(rawValue: id.replacingOccurrences(of: "tile.", with: "")), id.hasPrefix("tile.") { return canStart(tile) || inUse(tile) }
        if id == "status.stop", activity == .summarizing { return perch.dropped?.summarizing == true || staged != nil }
        if id == "underlines" { return Features.on(.write) && (underlines.enabled || frontName == nil) }
        // "Record a meeting": one recording at a time.
        if id == "meeting" { return Features.on(.meetings) && activity != .recording && (staged != nil || recorder.phase == .idle) }
        if id.hasPrefix("recent."), id.hasSuffix(".copy") || id.hasSuffix(".read") {
            if id.hasSuffix(".read"), !Features.on(.read) { return false }
            guard let item = item(for: id) else { return false }
            return item.kind == .document ? !item.body.isEmpty : !text(of: item).isEmpty
        }
        return true
    }

    /// A tile is off while the thing it starts is already under way (the first row has the way to stop it).
    func canStart(_ tile: MenuTile) -> Bool {
        guard Features.on(tile.feature) else { return false }
        switch tile {
        case .dictate: return activity != .dictating && activity != .writingDown && (staged != nil || dictation.phase == .idle)
        // A note opens in the perch whatever else is going on.
        case .note: return true
        case .read: return activity != .reading
        case .fix: return true
        case .summarize: return perch.dropped?.summarizing != true
        }
    }

    /// True for the tile whose action is under way: it is tinted, and pressing it stops the action.
    func inUse(_ tile: MenuTile) -> Bool {
        switch tile {
        case .dictate: activity == .dictating
        case .note: perch.notes.isOpen
        case .read: activity == .reading
        case .fix, .summarize: false
        }
    }

    /// A tile's key as the perch shows it: "hold ⌥" for Dictate, "⌥N" for Note. Nil when it has none.
    func key(for tile: MenuTile) -> String? {
        switch tile {
        case .dictate: ShortcutLayout.dictateLabel(holdKey: dictation.holdKey)
        case .note: ShortcutLayout.label(.recordNote, short: true)
        case .read: ShortcutLayout.label(.readSelection, short: true)
        case .fix: ShortcutLayout.label(.writePanel, short: true)
        case .summarize: ShortcutLayout.label(.summarize, short: true)
        }
    }

    private func item(for id: String) -> SavedItem? {
        let parts = id.split(separator: ".")
        guard parts.count >= 2, let index = Int(parts[1]) else { return nil }
        return recent[safe: index]
    }

    /// Presses a control, from a click or from Return or Space.
    func activate(_ id: String) {
        guard canUse(id) else { return }
        // The tile of the thing under way stops it, as the round button does.
        if let tile = MenuTile(rawValue: id.replacingOccurrences(of: "tile.", with: "")), id.hasPrefix("tile."), inUse(tile) { return activate("status.stop") }
        switch id {
        case "status.stop":
            switch activity {
            case .dictating: dictation.finish()
            case .recording: recorder.stop()
            // Closing the card is what cancels its summary; a document's own summary is not started from here.
            case .summarizing: if perch.dropped?.summarizing == true { perch.dropped = nil }
            case .transcribing: dictation.cancelImport()
            // The meeting stays saved with its transcript; "Write notes" writes them later.
            case .writingNotes: recorder.stopNotes()
            case .reading:
                pausedDocument = nil
                reader.dismiss()
            default: break
            }
            if staged != nil { staged = nil }
        case "status.play":
            if staged != nil { staged?.playing.toggle() } else {
                pausedDocument = reader.isPlaying ? reader.item?.id : nil
                reader.toggle()
            }
        case "status.cancel": Jobs.shared.cancelFirstWaiting()
        case "meeting":
            close()
            perch.recordMeeting()
        case "tile.dictate": leave { [perch] in perch.dictate() }
        case "tile.note":
            close()
            perch.note()
        case "tile.read": leave { [perch] in perch.read() }
        case "tile.fix": leave { [perch] in perch.fix() }
        case "tile.summarize": leave { [perch] in perch.summarizeHere() }
        case "holdKey": showHoldKeys()
        case "macSound": recorder.includesComputerSound.toggle()
        case "citations": reader.skipCitations.toggle()
        case "mic": showMicrophones()
        case "voice": showVoices()
        case "speed": break
        case "style": showStyles()
        case "underlines": setUnderlines(!underlinesOn)
        case "perch": perchShown.toggle()
        case "library":
            close()
            AppDelegate.showMain()
        case "settings":
            // Settings is a page of the Library window; there is no window of its own for it.
            close()
            AppDelegate.showSettings()
        case "quit": NSApp.terminate(nil)
        default:
            if id.hasPrefix("feature."), let feature = Feature(rawValue: String(id.dropFirst(8))) {
                return Features.shared.turn(feature, on: !Features.on(feature))
            }
            guard id.hasPrefix("recent."), let item = item(for: id) else { return }
            if id.hasSuffix(".copy") {
                copy(item)
            } else if id.hasSuffix(".read") {
                read(item)
            } else {
                close()
                app.open(item)
                AppDelegate.showMain()
            }
        }
    }

    /// The words of a captured item: a recording's notes (or what was said, when it has none), else its text.
    func text(of item: SavedItem) -> String {
        guard item.kind == .meeting || item.kind == .voiceNote else { return item.body }
        let notes = [item.summary, item.body].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if !notes.isEmpty { return MarkdownLines.plain(notes.joined(separator: "\n\n")) }
        return ((try? recorder.library.segments(itemID: item.id ?? -1)) ?? []).map(\.text).joined(separator: " ")
    }

    private func copy(_ item: SavedItem) {
        TextInserter.copy(text(of: item))
        copied = item.id
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            if self.copied == item.id { self.copied = nil }
        }
    }

    /// Reads a document from where it was left; anything else is read once and not kept as a document.
    private func read(_ item: SavedItem) {
        pausedDocument = nil
        if item.kind == .document {
            reader.open(item)
            if reader.item?.id == item.id { reader.play() }
        } else {
            reader.readOnce(DocumentImporter.Imported(title: LibraryRows.title(item), text: text(of: item), source: item.kind.label))
        }
    }

    // MARK: Quick settings

    /// Reading speed as a place along the slider: one stop for each speed Chirp offers.
    var speedStop: Double {
        get { Double(ReadController.speeds.enumerated().min { abs($0.element - reader.speed) < abs($1.element - reader.speed) }?.offset ?? 1) }
        set {
            let speed = ReadController.speeds[max(0, min(ReadController.speeds.count - 1, Int(newValue.rounded())))]
            if speed != reader.speed { reader.speed = speed }
        }
    }

    private func stepSpeed(_ by: Double) { speedStop += by }

    /// Underlines in the app that was in front; with no such app, underlines everywhere.
    var underlinesOn: Bool { frontName == nil ? underlines.enabled : underlines.enabled && underlinesHere }

    func setUnderlines(_ on: Bool) {
        guard let front = lastApp, let id = front.bundleIdentifier, frontName != nil else { return underlines.enabled = on }
        // The app's own switch, the one Writing style › By app shows. The checks pick it up within two seconds.
        var style = (try? app.engine.appStyle(bundleID: id)) ?? AppStyle(bundleID: id, appName: front.localizedName ?? id)
        style.underlinesEnabled = on
        try? app.engine.save(style)
        underlinesHere = on
    }

    /// "Show the perch": off hides it at rest (it still comes up to show work); on brings back how much showed before.
    var perchShown: Bool {
        get { perch.presence != .hidden && !perch.hiddenNow }
        set {
            if newValue {
                perch.hiddenUntil = nil
                perch.hiddenUntilShortcut = false
                if perch.presence == .hidden {
                    perch.presence = PerchPresence(rawValue: UserDefaults.standard.string(forKey: Self.presenceKey) ?? "") ?? .full
                }
            } else if perch.presence != .hidden {
                UserDefaults.standard.set(perch.presence.rawValue, forKey: Self.presenceKey)
                perch.presence = .hidden
            }
        }
    }

    /// Where a row's menu opens: under the row, at its right end.
    private func pop(_ menu: NSMenu, under id: String) {
        inMenu = true
        defer { inMenu = false }
        guard let view = host?.panel.contentView, let frame = frames[id] else {
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
            return
        }
        var point = NSPoint(x: frame.maxX - 190, y: frame.maxY + 2)
        if !view.isFlipped { point.y = view.bounds.height - point.y }
        menu.popUp(positioning: nil, at: point, in: view)
    }

    private func showMicrophones() {
        let menu = NSMenu()
        let chosen = AudioDevices.preferredUID
        menu.addItem(ClosureMenuItem("Same as macOS", on: chosen.isEmpty) { [weak self] in
            AudioDevices.preferredUID = ""
            self?.refresh()
        })
        menu.addItem(.separator())
        for input in AudioDevices.inputs() {
            menu.addItem(ClosureMenuItem(input.name, on: input.uid == chosen) { [weak self] in
                AudioDevices.preferredUID = input.uid
                self?.refresh()
            })
        }
        pop(menu, under: "mic")
    }

    /// The key held to dictate: Right Option unless another, or none, is chosen.
    private func showHoldKeys() {
        let menu = NSMenu()
        for key in HoldKey.allCases {
            menu.addItem(ClosureMenuItem(key.title, on: key == dictation.holdKey) { [weak self] in self?.dictation.holdKey = key })
        }
        pop(menu, under: "holdKey")
    }

    /// The hold key as the row shows it: "Right ⌥".
    var holdKeyName: String {
        switch dictation.holdKey {
        case .rightOption: "Right ⌥"
        case .rightCommand: "Right ⌘"
        case .fn: "Fn"
        case .none: "None"
        }
    }

    /// The writing style of the app that was in front, changed in place. The full
    /// list is Library › Writing style.
    private func showStyles() {
        let menu = NSMenu()
        for formality in Formality.allCases {
            menu.addItem(ClosureMenuItem(formality.rawValue.capitalized, on: formality == styleHere) { [weak self] in self?.setStyle(formality) })
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("All Writing Styles…") { [weak self] in
            self?.close()
            self?.perch.openWritingStyles()
        })
        pop(menu, under: "style")
    }

    func setStyle(_ formality: Formality) {
        guard let front = lastApp, let id = front.bundleIdentifier, frontName != nil else { return }
        try? app.engine.setFormality(formality, for: WorkContext(bundleID: id, appName: front.localizedName))
        styleHere = formality
        Log.write("write", "style in \(id): \(formality.rawValue) (menu bar)")
    }

    private func showVoices() {
        let menu = NSMenu()
        for voice in Voice.voices {
            menu.addItem(ClosureMenuItem("\(voice.name)  (\(voice.accent))", on: voice.id == reader.voiceID) { [weak self] in self?.reader.voiceID = voice.id })
        }
        pop(menu, under: "voice")
    }

    /// The voice in use, by name.
    var voiceName: String { Voice.voices.first { $0.id == reader.voiceID }?.name ?? "Voice" }

    // MARK: Test links

    /// `chirp://debug/menu?…` opens the popover and puts it in a state without any audio; `menu-shot` and
    /// `menu-icon` write pictures of the popover and of the menu bar item as they are on screen.
    private func registerDebug() {
        LinkHandler.commands["menu"] = { [weak self] q in
            guard let self else { return }
            if let state = q["state"] {
                switch state {
                case "recording": self.staged = Staged(activity: .recording, line: q["line"] ?? "12:04 · Launch review")
                case "dictating": self.staged = Staged(activity: .dictating, line: q["line"] ?? "0:08 · into Mail")
                case "reading": self.staged = Staged(activity: .reading, line: q["line"] ?? "How birds learn to sing")
                case "paused": self.staged = Staged(activity: .reading, line: q["line"] ?? "How birds learn to sing", playing: false)
                case "working": self.staged = Staged(activity: .writingDown, line: "Writing it down")
                case "summarizing": self.staged = Staged(activity: .summarizing, line: q["line"] ?? "Part 2 of 5 · How to pace your first half marathon")
                case "transcribing": self.staged = Staged(activity: .transcribing, line: q["line"] ?? "Designing calm software · YouTube", title: "Transcribing · 40%")
                case "writing": self.staged = Staged(activity: .ready, line: q["line"] ?? "Mail · 3 suggestions", title: "Checking your writing", situation: .writing)
                case "notes": self.staged = Staged(activity: .writingNotes, line: q["line"] ?? "Launch review")
                case "attention": self.staged = Staged(activity: .ready, attention: true)
                case "idle": self.staged = Staged(activity: .ready)
                default: self.staged = nil
                }
            }
            if let open = q["open"] {
                self.pinned = q["pin"] == "1"
                if open == "1" { self.host?.show(takeKey: !self.pinned || q["key"] == "1") }
                if open == "click" { self.host?.clicked() }
                if open == "0" { self.close() }
            }
            if let hover = q["hover"] {
                self.stagedHover = hover.isEmpty ? nil : hover
                self.setHovered(self.stagedHover)
            }
            if let focus = q["focus"] { self.focused = focus.isEmpty ? nil : focus }
            if let contrast = q["contrast"] { self.stagedContrast = contrast == "1" }
            if let code = q["key"].flatMap(UInt16.init),
                let event = NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: q["shift"] == "1" ? .shift : [], timestamp: 0, windowNumber: 0,
                    context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)
            {
                _ = self.key(event)
            }
            // A key as the keyboard would send it, through the app's own queue.
            if let code = q["press"].flatMap(UInt16.init), let panel = self.host?.panel,
                let event = NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: panel.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)
            {
                NSApp.postEvent(event, atStart: false)
            }
            if let id = q["do"] { self.activate(id) }
            // The settings area for a situation, whatever is going on (`menu?situation=reading`; empty for the real one).
            if let name = q["situation"] {
                if self.staged == nil, !name.isEmpty { self.staged = Staged(activity: .ready) }
                self.staged?.situation = MenuSituation(rawValue: name)
                self.refresh()
            }
            if q["state"] != nil || q["refresh"] == "1" { self.refresh() }
            // `menu?style=formal` picks from the Writing style row's menu.
            if let style = q["style"].flatMap(Formality.init(rawValue:)) { self.setStyle(style) }
        }
        // The popover alone, as it is on screen (its glass included).
        LinkHandler.commands["menu-shot"] = { [weak self] q in
            guard let path = q["path"], let window = self?.window, window.isVisible, window.windowNumber > 0,
                let image = LinkHandler.windowImage(window.windowNumber, options: (1 << 0) | (1 << 3))
            else { return }
            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
        // The menu bar item, drawn by its own button (so in the menu bar's own light or dark), on a plain
        // ground of that kind. Four times its size, so it can be looked at.
        LinkHandler.commands["menu-icon"] = { q in
            guard let path = q["path"], let button = MenuBarModel.shared?.host?.item.button,
                let drawn = button.bitmapImageRepForCachingDisplay(in: button.bounds)
            else { return }
            button.cacheDisplay(in: button.bounds, to: drawn)
            guard let image = drawn.cgImage else { return }
            let scale = 4 * button.bounds.width / CGFloat(image.width)
            let width = Int(CGFloat(image.width) * scale) + 48, height = Int(CGFloat(image.height) * scale) + 32
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
            guard let rep, let context = NSGraphicsContext(bitmapImageRep: rep)?.cgContext else { return }
            let dark = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            context.setFillColor(gray: dark ? 0.2 : 0.88, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 24, y: 16, width: width - 48, height: height - 32))
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
        LinkHandler.stateProviders["menu"] = { [weak self] in
            guard let self else { return [:] }
            return [
                "open": self.isOpen, "visible": self.window?.isVisible ?? false, "key": self.window?.isKeyWindow ?? false,
                "activity": self.activity.rawValue, "title": self.title, "line": self.line, "icon": "\(self.icon)",
                "hovered": self.hovered ?? "", "focused": self.focused ?? "", "recent": self.recent.map(LibraryRows.title),
                "front": self.frontName ?? "", "underlines": self.underlinesOn, "style": self.styleHere.rawValue, "canOpenMain": AppDelegate.openMain != nil,
                "perchShown": self.perchShown, "microphone": self.microphone, "voice": self.voiceName, "speed": self.reader.speed,
                "rows": self.rows, "situation": self.situation.rawValue, "heading": self.situation.heading(app: self.frontName),
                "settingsRows": self.situation.rows.map(\.rawValue), "recentKinds": self.recent.map(\.kind.rawValue), "holdKey": self.holdKeyName,
                "macSound": self.recorder.includesComputerSound, "citations": self.reader.skipCitations,
                "frame": self.window.map { NSStringFromRect($0.frame) } ?? "", "controls": self.frames.count,
                "showTimer": UserDefaults.standard.object(forKey: Self.timerKey) as? Bool ?? true,
                "inMenuBar": self.host?.item.isVisible ?? false, "pinned": self.pinned, "lastClose": self.host?.lastClose ?? "", "keyLog": self.host?.keyLog ?? [], "active": NSApp.isActive,
            ] as [String: Any]
        }
    }
}

/// The five things the popover can start, as the perch has them.
enum MenuTile: String, CaseIterable, Identifiable {
    case dictate, note, read, fix, summarize

    var id: String { "tile." + rawValue }

    /// The feature the tile starts. A tile is there only while its feature is switched on.
    var feature: Feature {
        switch self {
        case .dictate: .dictate
        case .note: .notes
        case .read: .read
        case .fix: .write
        case .summarize: .summarize
        }
    }

    /// The tiles for the features that are switched on, in their usual order.
    @MainActor static var shown: [MenuTile] { allCases.filter { Features.on($0.feature) } }

    var title: String {
        switch self {
        case .dictate: "Dictate"
        case .note: "Note"
        case .read: "Read"
        case .fix: "Fix"
        case .summarize: "Summarize"
        }
    }

    /// What VoiceOver says: the perch's names for the same actions.
    var spoken: String {
        switch self {
        case .dictate: "Dictate"
        case .note: "Note"
        case .read: "Read aloud"
        case .fix: "Fix writing"
        case .summarize: "Summarize"
        }
    }

    var symbol: String {
        switch self {
        case .dictate: "chirp.dictate"
        case .note: "chirp.note"
        case .read: "chirp.read"
        case .fix: "chirp.fix"
        case .summarize: "chirp.summarize"
        }
    }
}

// MARK: - The view

/// Where each control is, gathered up to the popover so the pointer and the keys can find them.
private struct MenuFrames: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

private extension View {
    /// Notes where this control is under its id.
    func menuFrame(_ id: String) -> some View {
        background(GeometryReader { geo in Color.clear.preference(key: MenuFrames.self, value: [id: geo.frame(in: .named("menu"))]) })
    }
}

/// The popover: status, Start, Recent, Settings, and the foot row.
struct MenuBarPopover: View {
    let model: MenuBarModel
    @Environment(\.colorSchemeContrast) private var contrast

    private var ink: GlassFill { GlassFill(strong: contrast == .increased || model.stagedContrast) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            status
            // With every feature switched off there is nothing to start.
            if !MenuTile.shown.isEmpty {
                heading("Start")
                tiles
                // Note on the tile opens a note in the perch; a meeting is started here.
                if Features.on(.meetings) { meetingRow }
            }
            // With every feature switched off nothing is listed, so there is no Recent.
            if !Features.shared.set.shownKinds.isEmpty {
                heading("Recent")
                recent
            }
            // The few settings that matter for what is being done; at rest, the feature switches.
            heading(model.situation.heading(app: model.frontName))
            settings
            foot
        }
        .font(.system(size: 13))
        .foregroundStyle(Color.primary)
        .padding(14)
        .frame(width: MenuBarModel.width)
        // One sheet of the system's glass, with enough of Chirp's surface colour over it for words to
        // stay readable above a busy page. With Reduce Transparency it is a solid surface.
        .chirpGlass(in: RoundedRectangle(cornerRadius: MenuBarModel.radius, style: .continuous), wash: 0.62)
        .coordinateSpace(name: "menu")
        .onPreferenceChange(MenuFrames.self) { frames in
            Task { @MainActor in model.frames = frames }
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { model.host?.fit($0) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Chirp")
    }

    private func heading(_ text: String) -> some View {
        Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle(ink.faint)
            // The perch's grid: 16 above a section's name, 6 under it.
            .padding(.top, 16).padding(.leading, 2).padding(.bottom, 6)
            .accessibilityAddTraits(.isHeader)
    }

    // MARK: Status

    private var status: some View {
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                Bird(mood: mood, size: 30).frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(model.title).font(.system(size: 13, weight: .semibold)).monospacedDigit().lineLimit(1)
                        // The Beta mark sits beside the status.
                        if Beta.isOn { BetaTag(onGlass: true) }
                    }
                    if !model.line.isEmpty {
                        Text(model.line).font(.system(size: 12)).monospacedDigit().foregroundStyle(ink.quiet).lineLimit(1).truncationMode(.tail)
                    }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(model.line.isEmpty ? "Chirp, \(model.title)" : "Chirp, \(model.title), \(model.line)")
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                switch model.activity {
                case .recording:
                    round("status.stop", symbol: "chirp.stop", label: "Stop recording", red: true)
                case .dictating:
                    round("status.stop", symbol: "chirp.stop", label: "Stop dictating")
                case .reading:
                    round("status.play", symbol: model.readingAloud ? "chirp.pause" : "chirp.play", label: model.readingAloud ? "Pause" : "Play")
                    round("status.stop", symbol: "chirp.stop", label: "Stop reading")
                case .waiting:
                    act("status.cancel", "Cancel", filled: true)
                case .summarizing:
                    round("status.stop", symbol: "chirp.stop", label: "Stop summarizing")
                case .transcribing:
                    round("status.stop", symbol: "chirp.stop", label: "Stop transcribing")
                case .writingNotes:
                    if model.canStopNotes { round("status.stop", symbol: "chirp.stop", label: "Stop writing notes") }
                case .ready, .writingDown:
                    EmptyView()
                }
            }
        }
        .frame(minHeight: 34)
    }

    /// Under the tiles: "Record a meeting", with its key at the right.
    private var meetingRow: some View {
        let on = model.canUse("meeting")
        return MenuControl(id: "meeting", model: model, ink: ink, shape: .rounded(8), rest: .clear, hover: ink.hover, enabled: on, label: "Record a meeting") {
            HStack(spacing: 8) {
                Text("Record a meeting").lineLimit(1)
                Spacer(minLength: 8)
                if let key = ShortcutLayout.label(.recordMeeting, short: true) {
                    Text(key).font(.system(size: 11)).foregroundStyle(ink.faint).accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 6).frame(height: 32)
        }
        .opacity(on ? 1 : 0.5)
        .padding(.horizontal, -6).padding(.top, 4)
        .accessibilityHint(on ? "For a meeting in the room, or one Chirp did not notice" : "A recording is already under way")
    }

    private var mood: BirdMood {
        switch model.activity {
        case .ready: .idle
        case .dictating, .recording: .listening
        case .writingDown, .writingNotes, .waiting, .summarizing, .transcribing: .thinking
        case .reading: model.readingAloud ? .speaking : .idle
        }
    }

    /// A round button of the first row. `red` is for stopping a recording, the one place red is used.
    private func round(_ id: String, symbol: String, label: String, red: Bool = false) -> some View {
        MenuControl(id: id, model: model, ink: ink, shape: .circle, rest: red ? Color.recordButton : ink.row, hover: red ? Color.recordButton.opacity(0.85) : ink.hover, label: label) {
            // The perch's round buttons: 34 across, with its icon size.
            Image(symbol).font(.system(size: 13, weight: .semibold))
                .foregroundStyle(red ? Color.white : Color.primary.opacity(0.85))
                .frame(width: 34, height: 34)
        }
    }

    // MARK: Start

    private var tiles: some View {
        HStack(spacing: 4) {
            ForEach(MenuTile.shown) { tile in
                let inUse = model.inUse(tile)
                let on = model.canStart(tile) || inUse
                // The action under way is tinted amber, the one accent on this sheet; pressing it stops it.
                MenuControl(
                    id: tile.id, model: model, ink: ink, shape: .rounded(12), rest: inUse ? Color.amber : ink.row, hover: inUse ? Color.amber.opacity(0.85) : ink.hover,
                    enabled: on, label: inUse ? "Stop: \(tile.spoken)" : tile.spoken
                ) {
                    VStack(spacing: 3) {
                        Image(tile.symbol).font(.system(size: 15)).frame(height: 18)
                        // Every name at one size; none shrinks to fit.
                        Text(tile.title).font(.system(size: 10.5)).tracking(-0.2).lineLimit(1).fixedSize()
                        // Its key, as on the perch's tiles ("hold ⌥", "⌥N").
                        if let key = model.key(for: tile) {
                            Text(key).font(.system(size: 10)).foregroundStyle(inUse ? Color.onAmber.opacity(0.75) : ink.faint).lineLimit(1)
                                .accessibilityHidden(true)
                        }
                    }
                    .foregroundStyle(inUse ? Color.onAmber : Color.primary.opacity(0.88))
                    .frame(maxWidth: .infinity).frame(height: 60)
                }
                .accessibilityHint(inUse ? "Stops it" : on ? model.key(for: tile).map { "Shortcut \($0)" } ?? "" : "Something else is under way")
            }
        }
    }

    // MARK: Recent

    @ViewBuilder
    private var recent: some View {
        if model.recent.isEmpty {
            Text("Nothing captured yet").foregroundStyle(ink.quiet).frame(height: 32)
        }
        ForEach(Array(model.recent.enumerated()), id: \.offset) { index, item in
            let id = "recent.\(index)"
            let lit = model.within(id)
            let recording = item.kind == .meeting || item.kind == .voiceNote
            MenuControl(id: id, model: model, ink: ink, shape: .rounded(8), rest: lit ? ink.row : .clear, hover: ink.row, label: LibraryRows.title(item)) {
                HStack(spacing: 8) {
                    // What kind of thing it is, as on Home.
                    Image(LibrarySection.holding(item.kind).symbol).font(.system(size: 13)).foregroundStyle(ink.quiet).frame(width: 18)
                        .accessibilityHidden(true)
                    Text(LibraryRows.title(item)).lineLimit(1).truncationMode(.tail)
                }
                // Copy and Read aloud have their own room at the end, lit or not, so the name is cut the same either way.
                .padding(.leading, 6).padding(.trailing, 70)
                .frame(maxWidth: .infinity, minHeight: 32, maxHeight: 32, alignment: .leading)
            }
            .accessibilityHint("Opens it in the Library")
            .accessibilityAction(named: recording ? "Copy notes" : "Copy") { model.activate(id + ".copy") }
            .recentReadAction(model: model, id: id)
            .overlay(alignment: .trailing) {
                if lit {
                    HStack(spacing: 2) {
                        small(id + ".copy", symbol: model.copied == item.id && item.id != nil ? "chirp.check" : "chirp.copy", label: recording ? "Copy notes" : "Copy")
                        if Features.on(.read) { small(id + ".read", symbol: "chirp.read", label: "Read aloud") }
                    }
                    .padding(.trailing, 3)
                }
            }
            .padding(.horizontal, -6)
        }
    }

    /// A small button at the right of a row.
    private func small(_ id: String, symbol: String, label: String) -> some View {
        MenuControl(id: id, model: model, ink: ink, shape: .capsule, rest: .clear, hover: ink.hover, enabled: model.canUse(id), label: label) {
            Image(symbol).font(.system(size: 12, weight: .medium)).foregroundStyle(ink.quiet).frame(width: 30, height: 26)
        }
        // VoiceOver reaches these as actions of the row, which do not depend on where the pointer is.
        .accessibilityHidden(true)
    }

    // MARK: Settings

    private var settings: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(model.situation.rows, id: \.self) { which in
                switch which {
                case .style:
                    // "Writing style" for the app in front, changed in place; the row under it names the
                    // app ("Underlines in Mail").
                    if let front = model.frontName {
                        choice("style", name: "Writing style", value: model.styleHere.rawValue.capitalized)
                            .accessibilityLabel("Writing style in \(front), \(model.styleHere.rawValue)")
                    }
                case .underlines:
                    let name = model.frontName.map { "Underlines in \($0)" } ?? "Underlines in other apps"
                    row("underlines") {
                        Text(name).lineLimit(1).accessibilityHidden(true)
                        Spacer(minLength: 8)
                        Toggle(name, isOn: Binding(get: { model.underlinesOn }, set: { model.setUnderlines($0) }))
                            .labelsHidden().toggleStyle(.switch).controlSize(.small)
                            .disabled(!model.canUse("underlines"))
                            .accessibilityHint(model.canUse("underlines") ? "" : "Underlines are off in Settings, under Writing")
                    }
                    .opacity(model.canUse("underlines") ? 1 : 0.5)
                case .microphone: choice("mic", name: "Microphone", value: model.microphone)
                case .holdKey: choice("holdKey", name: "Hold to dictate", value: model.holdKeyName)
                case .macSound:
                    toggleRow("macSound", "Include this Mac’s sound", isOn: Binding(get: { model.recorder.includesComputerSound }, set: { model.recorder.includesComputerSound = $0 }))
                case .voice: choice("voice", name: "Voice", value: model.voiceName)
                case .speed:
                    row("speed") {
                        Text("Speed").accessibilityHidden(true)
                        Slider(value: $model.speedStop, in: 0...Double(ReadController.speeds.count - 1))
                            .controlSize(.small)
                            .padding(.leading, 12)
                            .accessibilityLabel("Speed")
                            .accessibilityValue(model.reader.speed.speedLabel)
                        Text(model.reader.speed.speedLabel).font(.system(size: 12.5)).monospacedDigit().foregroundStyle(ink.quiet)
                            .frame(minWidth: 30, alignment: .trailing).padding(.leading, 8)
                            .accessibilityHidden(true)
                    }
                case .citations:
                    toggleRow("citations", "Leave out citation marks", isOn: Binding(get: { model.reader.skipCitations }, set: { model.reader.skipCitations = $0 }))
                case .features: featureChips
                case .perch: toggleRow("perch", "Show the perch", isOn: $model.perchShown)
                case .allSettings:
                    MenuControl(id: "settings", model: model, ink: ink, shape: .rounded(8), rest: .clear, hover: ink.row, label: "All settings") {
                        Text("All settings…").padding(.horizontal, 6).frame(maxWidth: .infinity, minHeight: 32, maxHeight: 32, alignment: .leading)
                    }
                    .padding(.horizontal, -6)
                }
            }
        }
    }

    /// The five feature switches as chips: filled with a tick when on, an outline when off.
    private var featureChips: some View {
        // Redrawn when a feature is switched from here or anywhere else.
        let _ = Features.shared.set
        return FlowLayout(spacing: 6, lineSpacing: 6) {
            ForEach(GeneralSettings.featureOrder) { feature in
                let on = Features.on(feature)
                MenuControl(id: "feature." + feature.rawValue, model: model, ink: ink, shape: .capsule, rest: on ? ink.row : .clear, hover: ink.hover, label: feature.title) {
                    HStack(spacing: 5) {
                        if on { Image("chirp.check").font(.system(size: 9, weight: .bold)) }
                        Text(feature.title).font(.system(size: 12)).lineLimit(1).fixedSize()
                    }
                    .foregroundStyle(on ? Color.primary.opacity(0.88) : ink.faint)
                    .padding(.leading, on ? 8 : 10).padding(.trailing, 10).frame(height: 26)
                    .overlay(Capsule().strokeBorder(ink.line, lineWidth: on ? 0 : 1))
                }
                .accessibilityValue(on ? "On" : "Off")
                .accessibilityHint(on ? "Switches \(feature.title) off everywhere" : "Switches \(feature.title) on")
            }
        }
        .padding(.bottom, 4)
    }

    /// A settings row with a switch at its right end.
    private func toggleRow(_ id: String, _ name: String, isOn: Binding<Bool>) -> some View {
        row(id) {
            Text(name).lineLimit(1).accessibilityHidden(true)
            Spacer(minLength: 8)
            Toggle(name, isOn: isOn).labelsHidden().toggleStyle(.switch).controlSize(.small)
        }
    }

    /// A settings row that holds a control of its own (a slider, a switch). The keyboard's ring goes round the row.
    private func row<Content: View>(_ id: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 0) { content() }
            .padding(.horizontal, 6)
            .frame(height: 32)
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.accentColor, lineWidth: 2).opacity(model.focused == id ? 1 : 0))
            .menuFrame(id)
            .padding(.horizontal, -6)
    }

    /// A settings row that shows a choice and opens a menu of the others.
    private func choice(_ id: String, name: String, value: String) -> some View {
        MenuControl(id: id, model: model, ink: ink, shape: .rounded(8), rest: .clear, hover: ink.row, label: "\(name), \(value)") {
            HStack(spacing: 4) {
                Text(name)
                Spacer(minLength: 12)
                Text(value).foregroundStyle(ink.quiet).lineLimit(1).truncationMode(.middle)
                Image("chirp.chevron").font(.system(size: 9, weight: .semibold)).foregroundStyle(ink.faint)
            }
            .padding(.horizontal, 6)
            .frame(height: 32)
        }
        .accessibilityHint("Opens a menu")
        .padding(.horizontal, -6)
    }

    // MARK: Foot

    private var foot: some View {
        HStack(spacing: 6) {
            act("library", "Open Library", filled: true)
            Spacer(minLength: 8)
            act("quit", "Quit")
        }
        // The same grid as the rest: 14 above the line, 12 under it.
        .padding(.top, 12)
        .overlay(alignment: .top) { Rectangle().fill(ink.line).frame(height: 1) }
        .padding(.top, 14)
    }

    private func act(_ id: String, _ title: String, filled: Bool = false) -> some View {
        MenuControl(id: id, model: model, ink: ink, shape: .capsule, rest: filled ? ink.row : .clear, hover: ink.hover, label: title) {
            Text(title).font(.system(size: 12.5)).foregroundStyle(Color.primary.opacity(0.88))
                .padding(.horizontal, 9).frame(height: 26)
        }
    }
}

/// One pressable thing in the popover: a fill at rest, a stronger one under the pointer, a ring when the
/// keyboard is on it. It notes where it is, and presses through the model so a key does the same as a click.
private struct MenuControl<Label: View>: View {
    enum Outline {
        case circle, capsule, rounded(CGFloat)

        var shape: AnyShape {
            switch self {
            case .circle: AnyShape(Circle())
            case .capsule: AnyShape(Capsule())
            case .rounded(let radius): AnyShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            }
        }
    }

    let id: String
    let model: MenuBarModel
    let ink: GlassFill
    let shape: Outline
    let rest: Color
    let hover: Color
    var enabled = true
    let label: String
    @ViewBuilder var content: () -> Label

    var body: some View {
        let outline = shape.shape
        Button { model.activate(id) } label: {
            content()
                .background(enabled && model.hovered == id ? hover : rest, in: outline)
                // With Increase Contrast every control has an edge, lit or not.
                .overlay(outline.stroke(Color.primary.opacity(ink.strong ? 0.5 : 0), lineWidth: 1))
                .overlay(outline.stroke(Color.accentColor, lineWidth: 2).opacity(model.focused == id ? 1 : 0))
                .contentShape(outline)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .menuFrame(id)
        .accessibilityLabel(label)
    }
}

/// The panel the popover is shown in: clear and borderless, floating over other apps. It takes the
/// keyboard while it is open without making Chirp the app in front.
final class MenuPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .popUpMenu
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovable = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .transient]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// The menu bar item, and the showing and hiding of its popover.
@MainActor
final class MenuBarHost: NSObject, NSWindowDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let panel = MenuPanel()
    private unowned let model: MenuBarModel
    /// Watches for a click anywhere else while the popover is open, which closes it.
    private var monitors: [Any] = []
    private var visibility: NSKeyValueObservation?
    private var observers: [NSObjectProtocol] = []
    /// When the keyboard came to the popover and left it, in seconds since it opened, for the test links' state.
    private(set) var keyLog: [String] = []
    private var shownAt = Date()
    /// Why the popover last closed, for the test links' state.
    private(set) var lastClose = ""
    /// From the bottom of the menu bar to the top of the popover.
    private static let gap: CGFloat = 5

    init(model: MenuBarModel) {
        self.model = model
        super.init()
        panel.contentView = FirstClickHostingView(rootView: MenuBarPopover(model: model))
        panel.delegate = self
        if let button = item.button {
            button.target = self
            button.action = #selector(clicked)
            _ = button.sendAction(on: [.leftMouseDown, .rightMouseDown])
            // The item is in the menu bar from launch, so it is where the app picks up the way to open
            // the Library window (SwiftUI only hands that out to a view).
            let opener = NSHostingView(rootView: MainWindowOpener())
            opener.frame = NSRect(x: 0, y: 0, width: 1, height: 1)
            button.addSubview(opener)
        }
        // "Show Chirp in the menu bar" (Settings › General). Dragging the item out of the menu bar turns it off.
        item.behavior = .removalAllowed
        syncInserted()
        visibility = item.observe(\.isVisible, options: [.new]) { _, change in
            guard change.newValue == false else { return }
            Task { @MainActor in
                if Self.inserted { UserDefaults.standard.set(false, forKey: DockPresence.menuBarKey) }
            }
        }
        observers.append(NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.syncInserted()
                self?.draw()
            }
        })
        // Another app coming forward closes the popover, as it does a menu.
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide(byItself: true, why: "another app came forward") }
        })
        follow()
    }

    /// The stored choice to show the item. On unless turned off.
    private static var inserted: Bool { UserDefaults.standard.object(forKey: DockPresence.menuBarKey) as? Bool ?? true }

    /// The choice last applied to the item, and whether it is being applied now. Changing `isVisible` makes AppKit save
    /// its own setting, which posts `UserDefaults.didChangeNotification` again from inside the change: without these
    /// the item would be set over and over until the stack ran out.
    private var appliedInserted: Bool?
    private var syncing = false

    private func syncInserted() {
        let wanted = Self.inserted
        guard !syncing, wanted != appliedInserted else { return }
        syncing = true
        defer { syncing = false }
        appliedInserted = wanted
        if item.isVisible != wanted { item.isVisible = wanted }
        if !wanted { hide() }
    }

    /// Draws the item for what Chirp is doing, and again whenever that changes.
    private func follow() {
        withObservationTracking { draw() } onChange: { [weak self] in
            Task { @MainActor in self?.follow() }
        }
    }

    private func draw() {
        guard let button = item.button else { return }
        let showTimer = UserDefaults.standard.object(forKey: MenuBarModel.timerKey) as? Bool ?? true
        MenuBarIcon.show(model.icon, dim: model.pulseDim, showTimer: showTimer, on: button)
    }

    @objc func clicked() {
        panel.isVisible ? hide() : show()
    }

    /// Opens the popover under the item.
    func show(takeKey: Bool = true) {
        guard !panel.isVisible, let button = item.button, let itemFrame = button.window?.frame else { return }
        model.willOpen()
        keyLog = []
        shownAt = Date()
        let size = panel.contentView?.fittingSize ?? NSSize(width: MenuBarModel.width, height: 520)
        place(size, under: itemFrame, on: button.window?.screen)
        // Key without Chirp coming forward: the app being used stays the app in front.
        panel.orderFrontRegardless()
        if takeKey { panel.makeKey() }
        monitors = [
            NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
                MainActor.assumeIsolated { self?.hide(byItself: true, why: "click elsewhere") }
            },
            NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
                // A click in another of Chirp's windows. One on the item itself is left to `clicked`.
                if let self, event.window !== self.panel, event.window !== self.item.button?.window, !self.model.inMenu { self.hide(byItself: true, why: "click in another Chirp window") }
                return event
            },
        ].compactMap { $0 }
        model.opened()
        // The item stays lit while its popover is open, as the system's own do.
        DispatchQueue.main.async { [weak self] in
            if self?.panel.isVisible == true { self?.item.button?.highlight(true) }
        }
    }

    /// Closes the popover. `byItself` is a close nobody asked for (a click elsewhere, another app coming
    /// forward): a popover pinned open by a test link stays.
    func hide(byItself: Bool = false, why: String = "asked") {
        guard panel.isVisible, !(byItself && model.pinned) else { return }
        lastClose = why
        panel.orderOut(nil)
        item.button?.highlight(false)
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        model.closed()
    }

    /// The popover's content came out a different size (a status line came or went): keep the panel to
    /// it, with its top edge where it is.
    func fit(_ size: CGSize) {
        guard panel.isVisible, abs(size.height - panel.frame.height) > 0.5 || abs(size.width - panel.frame.width) > 0.5 else { return }
        var frame = panel.frame
        frame.origin.y = frame.maxY - size.height
        frame.size = size
        panel.setFrame(frame, display: true)
        panel.invalidateShadow()
    }

    /// Under the item, centred on it, kept on the screen.
    private func place(_ size: NSSize, under itemFrame: NSRect, on screen: NSScreen?) {
        let visible = (screen ?? NSScreen.main)?.visibleFrame ?? itemFrame
        let x = min(max(itemFrame.midX - size.width / 2, visible.minX + 8), visible.maxX - size.width - 8)
        panel.setFrame(NSRect(x: x, y: itemFrame.minY - Self.gap - size.height, width: size.width, height: size.height), display: true)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        keyLog.append(String(format: "+%.2f", Date().timeIntervalSince(shownAt)))
    }

    func windowDidResignKey(_ notification: Notification) {
        keyLog.append(String(format: "-%.2f", Date().timeIntervalSince(shownAt)))
        // The keyboard went somewhere else: close, as a menu would. Waited for a moment, because the
        // keyboard also leaves and comes straight back (one of the popover's own menus, a link arriving).
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, self.panel.isVisible, !self.panel.isKeyWindow, !self.model.inMenu else { return }
            self.hide(byItself: true, why: "lost the keyboard")
        }
    }
}

private extension View {
    /// "Read aloud" as a VoiceOver action of a recent item, while Read aloud is switched on.
    @ViewBuilder func recentReadAction(model: MenuBarModel, id: String) -> some View {
        if Features.on(.read) {
            accessibilityAction(named: "Read aloud") { model.activate(id + ".read") }
        } else {
            self
        }
    }
}
