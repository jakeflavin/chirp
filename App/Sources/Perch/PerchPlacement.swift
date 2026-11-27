import AppKit
import ChirpCore
import ChirpML
import KeyboardShortcuts
import SwiftUI

// Where the perch is and whether it shows: dragging it, the landing spots, standing upright at a side
// edge, tucking away in full screen, hiding, and the menus that open from it.

/// Where the perch sits on a display. Five places it settles into, or exactly where it was dropped.
enum PerchSpot: Equatable {
    case bottomLeft, bottomCentre, bottomRight, leftEdge, rightEdge
    /// Anywhere else: the middle of the bar, as a part of the usable screen (0…1 across, 0…1 down).
    case free(x: Double, y: Double)

    /// The five places shown while dragging.
    static let landings: [PerchSpot] = [.bottomLeft, .bottomCentre, .bottomRight, .leftEdge, .rightEdge]

    /// At a side edge the bar stands upright.
    var isSide: Bool { self == .leftEdge || self == .rightEdge }

    /// As kept between launches.
    var stored: String {
        switch self {
        case .bottomLeft: "bottomLeft"
        case .bottomCentre: "bottomCentre"
        case .bottomRight: "bottomRight"
        case .leftEdge: "leftEdge"
        case .rightEdge: "rightEdge"
        case .free(let x, let y): String(format: "free:%.4f,%.4f", x, y)
        }
    }

    init?(stored: String) {
        switch stored {
        case "bottomLeft": self = .bottomLeft
        case "bottomCentre": self = .bottomCentre
        case "bottomRight": self = .bottomRight
        case "leftEdge": self = .leftEdge
        case "rightEdge": self = .rightEdge
        default:
            let parts = stored.dropFirst(5).split(separator: ",").compactMap { Double($0) }
            guard stored.hasPrefix("free:"), parts.count == 2 else { return nil }
            self = .free(x: min(max(parts[0], 0), 1), y: min(max(parts[1], 0), 1))
        }
    }

    /// The setting in Settings that matches this spot, when one does.
    var position: PerchPosition? {
        switch self {
        case .bottomLeft: .left
        case .bottomCentre: .centre
        case .bottomRight: .right
        default: nil
        }
    }
}

extension PerchPosition {
    var spot: PerchSpot {
        switch self {
        case .left: .bottomLeft
        case .centre: .bottomCentre
        case .right: .bottomRight
        }
    }
}

/// What the perch is holding beyond its bar. Each is part of the one surface, not a card of its own.
enum PerchContent: String {
    /// The pointer is resting on it: the same bar, taller, with names and shortcuts.
    case tiles
    /// A document that was dropped or summarized.
    case document
    /// The list of writing suggestions.
    case fixes
    /// Fix, rephrase and the rest, on the selected text.
    case rephrase
    /// "Say it as", while reading: how a word just spoken should sound.
    case sayItAs
    /// A recording's finished notes.
    case notes
    /// The live transcript and the user's own notes while recording.
    case meetingNotes
    /// A note, typed or dictated into: the perch grown into its editor.
    case note
}

/// What a status bubble is placed against: the bird it comes from and the surface it must stay clear of,
/// in the panel's coordinates.
struct BubbleAnchor: Equatable {
    var bird = CGRect.zero
    var surface = CGRect.zero
}

/// A point the surface is pinned to, and which part of the surface sits on it.
struct PerchPin: Equatable {
    var point: CGPoint
    var unit: UnitPoint
}

/// A menu item that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private var run: (() -> Void)?

    convenience init(_ title: String, key: String = "", modifiers: NSEvent.ModifierFlags = [.command], on: Bool = false, run: @escaping () -> Void) {
        self.init(title: title, action: #selector(fire), keyEquivalent: key)
        keyEquivalentModifierMask = modifiers
        target = self
        state = on ? .on : .off
        self.run = run
    }

    @objc private func fire() { run?() }

    /// Does what choosing the item does (for test links).
    func press() { run?() }
}

extension PerchController {
    /// From the screen's edge to the perch.
    static let margin: CGFloat = 12
    /// How much of a tucked perch still shows.
    nonisolated static let sliver: CGFloat = 12
    /// A dragged perch settles into a landing spot from this far away.
    static let snapDistance: CGFloat = 120

    // MARK: What is shown

    /// What the perch is holding beyond its bar, if anything. One thing at a time.
    var content: PerchContent? {
        let mode = mode
        if showMeetingNotes, mode == .meeting { return .meetingNotes }
        // A note stays open while words are dictated into it and written down.
        if notes.isOpen, mode == .rest || mode == .dictating || mode == .working { return .note }
        if reader.sayItAs?.place == .perch, mode == .reading { return .sayItAs }
        if selection.shown, mode == .rest { return .rephrase }
        if showFixes, mode == .rest { return .fixes }
        // A line on the bar passes; what is open stays for when it has gone.
        if finished != nil, mode == .rest { return .notes }
        // A file dropped while recording is shown above the recording's bar, with "Attach to this recording".
        if dropped != nil, mode == .rest || mode == .reading || mode == .meeting { return .document }
        if hovering, mode == .rest, presence != .hidden, !dragging, !tucked { return .tiles }
        return nil
    }

    /// The bar stands upright: docked at a side edge, always. The column keeps its shape; anything the
    /// perch holds opens beside the column, toward the middle of the screen, as part of the one surface.
    /// What the bird says (a status, a call offer) is a bubble beside it.
    var upright: Bool { spot.isSide && !dragging }

    /// Hidden at rest for now, by "Hide for an Hour" or "Hide Until I Use a Shortcut".
    var hiddenNow: Bool { hiddenUntilShortcut || (hiddenUntil.map { Date() < $0 } ?? false) }

    // MARK: Where it goes

    /// The display key a spot is remembered under.
    static func key(for screen: NSScreen) -> String {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
            let uuid = CGDisplayCreateUUIDFromDisplayID(number)?.takeRetainedValue()
        else { return screen.localizedName }
        return CFUUIDCreateString(nil, uuid) as String
    }

    /// Puts the panel over the perch's display and works out the part of it the perch may use. Run at
    /// launch, and again when the displays change or the perch is carried to another one.
    func place() {
        let screens = NSScreen.screens
        let remembered = UserDefaults.standard.string(forKey: "perchDisplay")
        let chosen = screen.flatMap { s in screens.first { $0 == s } }
            ?? screens.first { Self.key(for: $0) == remembered }
            ?? NSScreen.main ?? screens.first
        guard let chosen else { return }
        if screen != chosen {
            screen = chosen
            let spots = UserDefaults.standard.dictionary(forKey: "perchSpots") as? [String: String] ?? [:]
            spot = spots[Self.key(for: chosen)].flatMap(PerchSpot.init(stored:)) ?? position.spot
        }
        if panel.frame != chosen.frame { panel.setFrame(chosen.frame, display: true) }
        // Over a full-screen app there is no menu bar or Dock to keep clear of.
        let usable = frontFullScreen ? chosen.frame : chosen.visibleFrame
        let area = CGRect(x: usable.minX - chosen.frame.minX, y: chosen.frame.maxY - usable.maxY, width: usable.width, height: usable.height)
        if area != bounds { bounds = area }
    }

    /// Moves the perch to a spot on its display and remembers it there.
    func setSpot(_ new: PerchSpot) {
        spot = new
        if let screen {
            var spots = UserDefaults.standard.dictionary(forKey: "perchSpots") as? [String: String] ?? [:]
            spots[Self.key(for: screen)] = new.stored
            UserDefaults.standard.set(spots, forKey: "perchSpots")
            UserDefaults.standard.set(Self.key(for: screen), forKey: "perchDisplay")
        }
        if let match = new.position, match != position {
            syncingSpot = true
            position = match
            syncingSpot = false
        }
    }

    /// Where the bar rests for a spot, in the panel's coordinates.
    func restFrame(for spot: PerchSpot) -> CGRect {
        let m = Self.margin
        let flat = barSize
        let tall = CGSize(width: PerchStyle.barHeight, height: PerchStyle.barLength(tall: false, upright: true))
        switch spot {
        case .bottomLeft: return CGRect(x: bounds.minX + m, y: bounds.maxY - m - flat.height, width: flat.width, height: flat.height)
        case .bottomCentre: return CGRect(x: bounds.midX - flat.width / 2, y: bounds.maxY - m - flat.height, width: flat.width, height: flat.height)
        case .bottomRight: return CGRect(x: bounds.maxX - m - flat.width, y: bounds.maxY - m - flat.height, width: flat.width, height: flat.height)
        case .leftEdge: return CGRect(x: bounds.minX + m, y: bounds.midY - tall.height / 2, width: tall.width, height: tall.height)
        case .rightEdge: return CGRect(x: bounds.maxX - m - tall.width, y: bounds.midY - tall.height / 2, width: tall.width, height: tall.height)
        case .free(let x, let y):
            let centre = CGPoint(x: bounds.minX + x * bounds.width, y: bounds.minY + y * bounds.height)
            return CGRect(x: centre.x - flat.width / 2, y: centre.y - flat.height / 2, width: flat.width, height: flat.height)
        }
    }

    /// A perch docked at a side edge, or dropped in the top half of the screen, opens downward: the
    /// bar row stays at the top, where the bird already is, and what it shows hangs below it.
    var opensDown: Bool {
        guard !dragging else { return false }
        if spot.isSide { return true }
        if case .free(_, let y) = spot { return y < 0.5 }
        return false
    }

    /// The point the surface is pinned to. The bar stays where it is and the surface grows away from
    /// that point, toward the middle of the screen.
    var pin: PerchPin {
        var pin = restPin
        // Grown taller under the pointer: slid along so the action that was under the pointer still is.
        // The placer keeps it on the screen.
        if content == .tiles, let anchor = hoverAnchor {
            let part = PerchStyle.itemCentre(anchor.item, tall: true, upright: upright) / PerchStyle.barLength(tall: true, upright: upright)
            if upright {
                pin.point.y = anchor.at
                pin.unit = UnitPoint(x: pin.unit.x, y: part)
            } else {
                pin.point.x = anchor.at
                pin.unit = UnitPoint(x: part, y: pin.unit.y)
            }
        }
        return pin
    }

    /// The pin without regard to the pointer: where the surface sits for its spot.
    private var restPin: PerchPin {
        let m = Self.margin
        if dragging {
            return PerchPin(point: CGPoint(x: dragCentre.x, y: dragCentre.y + barSize.height / 2), unit: .bottom)
        }
        switch spot {
        case .bottomLeft: return PerchPin(point: CGPoint(x: bounds.minX + m, y: bounds.maxY - m), unit: .bottomLeading)
        case .bottomCentre: return PerchPin(point: CGPoint(x: bounds.midX, y: bounds.maxY - m), unit: .bottom)
        case .bottomRight: return PerchPin(point: CGPoint(x: bounds.maxX - m, y: bounds.maxY - m), unit: .bottomTrailing)
        // At a side edge the top stays where the resting bar's top is, whatever is showing, so the
        // bird does not jump as the bar changes length.
        case .leftEdge: return PerchPin(point: CGPoint(x: bounds.minX + m, y: restFrame(for: spot).minY), unit: .topLeading)
        case .rightEdge: return PerchPin(point: CGPoint(x: bounds.maxX - m, y: restFrame(for: spot).minY), unit: .topTrailing)
        case .free:
            let bar = restFrame(for: spot)
            return opensDown
                ? PerchPin(point: CGPoint(x: bar.midX, y: bar.minY), unit: .top)
                : PerchPin(point: CGPoint(x: bar.midX, y: bar.maxY), unit: .bottom)
        }
    }

    /// The edge a tucked perch slides under.
    var tuckEdge: Edge {
        switch spot {
        case .leftEdge: .leading
        case .rightEdge: .trailing
        default: .bottom
        }
    }

    // MARK: Dragging

    /// The pointer moved with the bird (or the bare bar) held. The first call picks the perch up.
    func dragMoved() {
        let mouse = NSEvent.mouseLocation
        if !dragging {
            let centre = CGPoint(x: panel.frame.minX + barFrame.midX, y: panel.frame.maxY - barFrame.midY)
            grab = CGSize(width: mouse.x - centre.x, height: mouse.y - centre.y)
            // A bar picked up while upright is held by its middle.
            if upright { grab = .zero }
            hovering = false
            dragging = true
        }
        // Carried onto another display: the panel goes with it.
        if let over = NSScreen.screens.first(where: { $0.frame.contains(mouse) }), over != screen {
            screen = over
            place()
        }
        let centre = CGPoint(x: mouse.x - grab.width - panel.frame.minX, y: panel.frame.maxY - (mouse.y - grab.height))
        dragCentre = centre
        nearSpot = nearest(to: centre)
    }

    /// Let go: it settles into the landing spot it is near, or stays exactly where it is.
    func dragEnded() {
        guard dragging else { return }
        let landed = nearSpot ?? freeSpot(at: dragCentre)
        heldByLink = false
        dragging = false
        nearSpot = nil
        setSpot(landed)
    }

    /// The landing spot within reach of a point, if any.
    private func nearest(to point: CGPoint) -> PerchSpot? {
        let reach = PerchSpot.landings.map { spot -> (PerchSpot, CGFloat) in
            let frame = restFrame(for: spot)
            return (spot, hypot(frame.midX - point.x, frame.midY - point.y))
        }
        guard let best = reach.min(by: { $0.1 < $1.1 }), best.1 <= Self.snapDistance else { return nil }
        return best.0
    }

    /// A free spot for a bar whose middle is at `point`, kept clear of the menu bar, the Dock and the edges.
    private func freeSpot(at point: CGPoint) -> PerchSpot {
        let inset = bounds.insetBy(dx: Self.margin + barSize.width / 2, dy: Self.margin + barSize.height / 2)
        let x = min(max(point.x, inset.minX), max(inset.minX, inset.maxX))
        let y = min(max(point.y, inset.minY), max(inset.minY, inset.maxY))
        return .free(x: (x - bounds.minX) / max(bounds.width, 1), y: (y - bounds.minY) / max(bounds.height, 1))
    }

    /// For test links: opens the taller bar as if the pointer had come to rest on one of the actions
    /// (0…4, then More as 5), so the way it stays under the pointer and returns can be looked at.
    func debugPoint(at asked: Int) {
        // With features switched off there are fewer actions; anything past the last one is More.
        let item = min(asked, PerchStyle.actionCount)
        let start = upright ? barFrame.minY : barFrame.minX
        hoverAnchor = (item, start + PerchStyle.itemCentre(item, tall: false, upright: upright))
    }

    /// For test links: holds the perch at a place on the screen as if it were being dragged there.
    func debugDrag(toFraction at: CGPoint) {
        hovering = false
        heldByLink = true
        dragging = true
        grab = .zero
        dragCentre = CGPoint(x: bounds.minX + at.x * bounds.width, y: bounds.minY + at.y * bounds.height)
        nearSpot = nearest(to: dragCentre)
    }

    // MARK: Full screen, and hiding

    /// Notes whether a full-screen app is in front on the perch's display, and gives the perch the
    /// whole screen to work in when one is.
    func lookForFullScreen() {
        let full = debugFullScreen ?? Self.frontAppIsFullScreen(on: screen)
        guard full != frontFullScreen else { return }
        frontFullScreen = full
        // Arriving in full screen, the perch goes straight under the edge.
        revealed = false
        place()
    }

    /// True when the app in front has a window covering the whole of `screen`, menu bar included.
    /// Read from the window list's sizes, which needs no permission.
    static func frontAppIsFullScreen(on screen: NSScreen?) -> Bool {
        guard let screen, let front = NSWorkspace.shared.frontmostApplication,
            front.processIdentifier != ProcessInfo.processInfo.processIdentifier,
            let primary = NSScreen.screens.first,
            let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return false }
        // The window list counts down from the top of the first display.
        let whole = CGRect(x: screen.frame.minX, y: primary.frame.maxY - screen.frame.maxY, width: screen.frame.width, height: screen.frame.height)
        let notch = screen.safeAreaInsets.top
        for window in windows {
            guard (window[kCGWindowOwnerPID as String] as? Int).map({ pid_t($0) }) == front.processIdentifier,
                window[kCGWindowLayer as String] as? Int == 0,
                let dict = window[kCGWindowBounds as String] as? NSDictionary,
                let frame = CGRect(dictionaryRepresentation: dict)
            else { continue }
            if abs(frame.minX - whole.minX) < 2, abs(frame.width - whole.width) < 2, abs(frame.maxY - whole.maxY) < 2,
                frame.minY <= whole.minY + notch + 1
            {
                return true
            }
        }
        return false
    }

    /// A Chirp shortcut was pressed: a hidden perch comes back, and a tucked one comes out for a moment.
    func shortcutUsed() {
        hiddenUntilShortcut = false
        revealUntil = Date().addingTimeInterval(4)
        if tucked { tucked = false }
    }

    func hideForAnHour() {
        hiddenUntilShortcut = false
        hiddenUntil = Date().addingTimeInterval(3600)
        hovering = false
    }

    func hideUntilShortcut() {
        hiddenUntil = nil
        hiddenUntilShortcut = true
        hovering = false
    }

    func openSettings() {
        NSApp.activate()
        AppDelegate.openSettings?()
    }

    // MARK: Menus

    /// The menu for a right click at `point` in the panel: the bird's menu when the click is on the bird.
    func birdMenu(at point: CGPoint) -> NSMenu? {
        guard birdFrame.insetBy(dx: -6, dy: -6).contains(point) else { return nil }
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem("Hide for an Hour") { [weak self] in self?.hideForAnHour() })
        menu.addItem(ClosureMenuItem("Hide Until I Use a Shortcut") { [weak self] in self?.hideUntilShortcut() })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Tuck Away in Full Screen", on: hideInFullScreen) { [weak self] in self?.hideInFullScreen.toggle() })
        menu.addItem(ClosureMenuItem("Move to Bottom Centre") { [weak self] in self?.setSpot(.bottomCentre) })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Settings…", key: ",") { [weak self] in self?.openSettings() })
        menu.addItem(ClosureMenuItem("Customize Perch…") { [weak self] in self?.openCustomize() })
        return menu
    }

    /// A click on the chevron at the end of the perch: keeps the extended area open until it is clicked
    /// again. There is no "More" button on the perch.
    func pressMore() {
        let pin = !(extendedPinned && extendedOpen)
        withAnimation(GlassMotion.shape(growing: pin, reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)) {
            extendedPinned = pin
            extendedOpen = pin
        }
    }

    /// The "…" at the end of the extended area: the one-off items.
    func showMoreMenu() {
        let menu = moreMenu()
        moreMenuTitles = menu.items.map { $0.isSeparatorItem ? "-" : $0.title + ($0.action == nil && $0.submenu == nil ? " (off)" : "") }
        if debugMenuOnly { return }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    /// A right click on the perch away from the bird: the same items, then Customize Perch….
    func perchMenu() -> NSMenu {
        let menu = moreMenu()
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Customize Perch…") { [weak self] in self?.openCustomize() })
        return menu
    }

    /// Customize Perch…: the sheet, on the Settings window at Perch.
    func openCustomize() {
        app.settingsTab = .perch
        AppDelegate.showSettings()
        customizing = true
    }

    /// The … menu as it would open now: the one-off items, and any action that is neither on the perch
    /// nor in the extended area. `selected` stands in for the selection of the app in front (a test link
    /// has no other app to select text in).
    func moreMenu(front given: (id: String, name: String)? = nil, selected given2: String? = nil) -> NSMenu {
        let menu = NSMenu()
        let on = Features.shared.set
        let loose = Set(arrangement.unplaced.filter { $0.isOn(on) })
        // Taken off the perch: still to be found here.
        var main: [NSMenuItem] = []
        if loose.contains(.dictate) { main.append(ClosureMenuItem("Dictate") { [weak self] in self?.dictate() }) }
        if loose.contains(.note) { main.append(shortcutItem("New Note", .recordNote) { [weak self] in self?.note() }) }
        if loose.contains(.read) { main.append(shortcutItem("Read Aloud", .readSelection) { [weak self] in self?.read() }) }
        if loose.contains(.fix) { main.append(shortcutItem("Fix Writing", .writePanel) { [weak self] in self?.fix() }) }
        if loose.contains(.summarize) { main.append(shortcutItem("Summarize", .summarize) { [weak self] in self?.summarizeHere() }) }
        if loose.contains(.meeting) {
            // For a meeting in the room, or one Chirp did not notice.
            let meeting = shortcutItem("Record a Meeting", .recordMeeting) { [weak self] in self?.recordMeeting() }
            // One recording at a time: while one runs, or is being finished, the row cannot act.
            if recorder.phase != .idle {
                meeting.target = nil
                meeting.action = nil
            }
            main.append(meeting)
        }
        if loose.contains(.rephrase) { main.append(shortcutItem("Rephrase…", .rephrase) { [weak self] in self?.rephrase() }) }
        if !main.isEmpty {
            main.forEach(menu.addItem)
            menu.addItem(.separator())
        }
        // The app the user is in: the perch never comes to the front, so it is still the one in front.
        let running = NSWorkspace.shared.frontmostApplication.flatMap { $0.bundleIdentifier == Bundle.main.bundleIdentifier ? nil : $0 }
        let front: (id: String, name: String)? = given ?? running.flatMap { app in app.bundleIdentifier.map { ($0, app.localizedName ?? "This App") } }
        if on.isOn(.write) || on.isOn(.dictate) {
            if loose.contains(.snippet) {
                // Greyed unless text is selected in the app in front. It asks for a cue, then the text is in Snippets.
                let save = ClosureMenuItem("Save as a Snippet…") { [weak self] in self?.saveSelectionAsSnippet() }
                let selected = (given2 ?? TextInserter.selectedText())?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if selected.isEmpty || front == nil {
                    save.target = nil
                    save.action = nil
                }
                menu.addItem(save)
            }
            // The writing style of the app in front, changed in place.
            if let front {
                let id = front.id
                let context = WorkContext(bundleID: id, appName: front.name)
                let now = (try? app.engine.formality(for: context)) ?? .neutral
                let style = NSMenuItem(title: "Style in \(front.name): \(now.rawValue.capitalized)", action: nil, keyEquivalent: "")
                let choices = NSMenu()
                for formality in Formality.allCases {
                    choices.addItem(ClosureMenuItem(formality.rawValue.capitalized, on: formality == now) { [weak self] in
                        try? self?.app.engine.setFormality(formality, for: context)
                        Log.write("write", "style in \(id): \(formality.rawValue) (perch)")
                    })
                }
                choices.addItem(.separator())
                choices.addItem(ClosureMenuItem("All Writing Styles…") { [weak self] in self?.openWritingStyles() })
                style.submenu = choices
                menu.addItem(style)
            }
            if menu.items.last?.isSeparatorItem == false { menu.addItem(.separator()) }
        }
        if loose.contains(.typeAgain) {
            menu.addItem(shortcutItem("Type the Last Dictation Again", .pasteLast) { [weak self] in
                // The keyboard goes back to the app being typed in first.
                self?.giveKeyboardBack()
                self?.dictation.pasteLast()
            })
            menu.addItem(.separator())
        }
        if loose.contains(.library) { menu.addItem(shortcutItem("Library", .openLibrary) { [weak self] in self?.openLibrary() }) }
        menu.addItem(ClosureMenuItem("Settings…", key: ",") { [weak self] in self?.openSettings() })
        menu.autoenablesItems = true
        return menu
    }

    /// What an action on the bar or in the extended area does.
    func run(_ action: PerchAction) {
        switch action {
        case .dictate: dictate()
        case .note: note()
        case .read: read()
        case .fix: fix()
        case .summarize: summarizeHere()
        case .meeting: recordMeeting()
        case .rephrase: rephrase()
        case .snippet: saveSelectionAsSnippet()
        case .typeAgain:
            giveKeyboardBack()
            dictation.pasteLast()
        case .library: openLibrary()
        }
    }

    // MARK: The note

    /// A note opened in the perch: it takes the keyboard, and whatever else was open makes way.
    func noteOpened() {
        selection.close()
        showFixes = false
        finished = nil
        if let doc = dropped, !doc.summarizing { dropped = nil }
        hovering = false
        hoverAnchor = nil
        // The panel becomes the key window without making Chirp the active app; the editor takes the
        // keyboard itself once it is in the panel. Looked at again a moment later, in case the editor
        // was not ready or the panel was put back meanwhile, so the user never has to click into it.
        panel.makeKey()
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, self.notes.isOpen else { return }
            self.notes.focusEditor()
            // macOS can refuse the key window to an app in the background. Then Chirp comes forward for as
            // long as the note is open, and the app the user was in comes back when it closes.
            if !self.panel.isKeyWindow, !NSApp.isActive {
                self.cameForward = NSWorkspace.shared.frontmostApplication
                NSApp.activate()
                self.panel.makeKey()
                self.notes.focusEditor()
                Log.write("notes", "the perch could not take the keyboard in the background, so Chirp came forward")
            }
        }
    }

    /// Gives the front back to the app the user was in, when a note brought Chirp forward to take the keyboard.
    func noteGaveBackFront() {
        guard let app = cameForward else { return }
        cameForward = nil
        if NSApp.isActive, !(AppDelegate.mainWindow?.isVisible ?? false) { app.activate() }
    }

    /// The note was closed: the keyboard goes back, and the bird says where it went.
    func noteClosed(_ saved: SavedItem?, announce: Bool) {
        giveKeyboardBack()
        noteGaveBackFront()
        guard announce, let saved else { return }
        say("Saved to Notes", action: ("Open", { [weak self] in
            self?.app.open(saved)
            AppDelegate.showMain()
        }))
    }

    /// More › Save as a Snippet…: the cue is asked for on the perch, over the words selected in the app in front.
    func saveSelectionAsSnippet() {
        showFixes = false
        Task { await selection.saveSelectionAsSnippet() }
    }

    /// The full list of styles: Library › Writing style.
    func openWritingStyles() {
        app.section = .style
        AppDelegate.showMain()
    }

    /// What else can be done with a summarized document: the things its foot row has no room for.
    func showDocumentMenu() {
        let menu = NSMenu()
        // Only what is switched on is offered.
        if Features.on(.read) { menu.addItem(ClosureMenuItem("Read the Document Aloud") { [weak self] in self?.readDropped() }) }
        // Only while a recording is being made, and only for a file: dropping one never starts a recording.
        if Features.shared.set.records, recorder.phase == .recording, dropped?.url != nil {
            menu.addItem(ClosureMenuItem("Attach to This Recording") { [weak self] in self?.attachDropped() })
        }
        guard !menu.items.isEmpty else { return }
        menu.autoenablesItems = true
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    /// The voice and speed button while reading aloud: every voice, then every speed.
    func showVoiceMenu() {
        let menu = NSMenu()
        for voice in Voice.voices {
            menu.addItem(ClosureMenuItem("\(voice.name)  (\(voice.accent))", on: voice.id == reader.voiceID) { [weak self] in self?.reader.voiceID = voice.id })
        }
        menu.addItem(.separator())
        for speed in ReadController.speeds {
            menu.addItem(ClosureMenuItem(speed.speedLabel, on: speed == reader.speed) { [weak self] in self?.reader.speed = speed })
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    /// A menu item that shows a shortcut's keys beside its name.
    private func shortcutItem(_ title: String, _ name: KeyboardShortcuts.Name, run: @escaping () -> Void) -> NSMenuItem {
        let item = ClosureMenuItem(title, run: run)
        item.setShortcut(for: name)
        return item
    }

    // MARK: Pulling it taller

    /// How tall the part above the bar is when it first opens.
    static let bodyDefault: Double = 210
    /// The least it can be pulled down to.
    static let bodyLeast: Double = 96

    /// The most the part above the bar can be: the whole surface comes to about 70% of the usable screen.
    var bodyMost: Double { max(Self.bodyDefault, Double(bounds.height) * 0.7 - 150) }

    /// How tall the scrolling part may be for a kind of content. Shorter content takes only what it needs.
    func bodyHeight(for kind: PerchContent) -> Double {
        min(max(bodyHeights[kind.rawValue] ?? Self.bodyDefault, Self.bodyLeast), bodyMost)
    }

    /// The same, held to what fits beside an upright column: the column keeps its resting height until
    /// the surface is pulled taller. `chrome` is the head and foot rows around the scrolling part.
    func bodyLimit(for kind: PerchContent, chrome: Double = 100) -> Double {
        let asked = bodyHeight(for: kind)
        guard upright, !isTall(kind) else { return asked }
        return min(asked, Double(PerchStyle.busySize(upright: true).height) - chrome)
    }

    /// True once it has been pulled past how it opens.
    func isTall(_ kind: PerchContent) -> Bool { bodyHeight(for: kind) > Self.bodyDefault + 20 }

    /// How wide the surface is for a kind of content: a little wider as it is pulled taller.
    func width(for kind: PerchContent) -> CGFloat {
        let extra = (bodyHeight(for: kind) - Self.bodyDefault) / max(bodyMost - Self.bodyDefault, 1)
        return 420 + 100 * CGFloat(min(max(extra, 0), 1))
    }

    func setBodyHeight(_ height: Double, for kind: PerchContent) {
        bodyHeights[kind.rawValue] = min(max(height, Self.bodyLeast), bodyMost)
        UserDefaults.standard.set(bodyHeights, forKey: "perchBodyHeights")
    }

    /// The arrows button: all the way up, or back to how it opens.
    func toggleTall(_ kind: PerchContent) {
        setBodyHeight(isTall(kind) ? Self.bodyDefault : bodyMost, for: kind)
    }

    /// The handle is being pulled: `by` points toward the bar make it shorter, away make it taller.
    func pull(_ kind: PerchContent, by distance: Double) {
        if pullFrom == nil { pullFrom = bodyHeight(for: kind) }
        setBodyHeight((pullFrom ?? Self.bodyDefault) + distance, for: kind)
    }

    func pullEnded() { pullFrom = nil }
}
