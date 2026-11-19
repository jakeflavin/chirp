import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Puts text into whatever app the user is typing in.
///
/// The words are always pasted: put on the clipboard, ⌘V sent, and the clipboard put back
/// once the app has read it. Without Accessibility permission they are left on the clipboard, with a
/// message saying so.
///
/// Replacing the selection directly through Accessibility, with paste as the fallback, was tried in
/// TextEdit, Notes, Obsidian and Mail, ten inserts each way: every way put
/// every insert in the right place and left the clipboard as it was. The direct way was quicker (about
/// 10–20 ms against 60–80 ms) but broke undo: in Notes one ⌘Z also took back the words typed just before,
/// and in TextEdit and Notes several inserts in a row were undone as one. A pasted insert is one undo.
@MainActor
enum TextInserter {
    /// How the text got there, so the caller can tell the user when it could only be copied.
    enum Outcome: Equatable {
        /// Put straight into the field through Accessibility.
        case inserted
        /// Pasted with the clipboard, which is put back afterwards.
        case pasted
        /// Could not type into the app; the text is on the clipboard.
        case copiedOnly
    }

    /// Puts `text` at the cursor (over the selection, if there is one) in the app in front.
    static func insert(_ text: String) async -> Outcome {
        guard !text.isEmpty else { return .inserted }
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"
        guard AXIsProcessTrusted() else {
            copy(text)
            Log.write("insert", "no Accessibility permission: copied \(text.count) characters instead (front app \(front))")
            return .copiedOnly
        }
        await paste(text)
        Log.write("insert", "pasted \(text.count) characters into \(front)")
        return .pasted
    }

    /// Leaves `text` on the clipboard for the user to paste.
    static func copy(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    // MARK: Accessibility

    /// The element that has the keyboard, in whichever app is in front.
    static func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &value) == .success,
            let value, CFGetTypeID(value) == AXUIElementGetTypeID()
        {
            return (value as! AXUIElement)
        }
        // Asked of the whole system, some apps fail to answer while a web view has the keyboard (Mail's
        // compose window does). The app in front is then asked itself.
        guard let front = NSWorkspace.shared.frontmostApplication, front.bundleIdentifier != Bundle.main.bundleIdentifier else { return nil }
        var own: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(front.processIdentifier), kAXFocusedUIElementAttribute as CFString, &own) == .success,
            let own, CFGetTypeID(own) == AXUIElementGetTypeID()
        else { return nil }
        return (own as! AXUIElement)
    }

    // MARK: Text markers
    //
    // WebKit's editable pages (Mail's compose window, a text box on a page in Safari) do not give their text
    // as a value or their cursor as a range of characters. They answer through "text markers": opaque
    // places in the text, which can be turned into characters and back. Positions counted this way are
    // UTF-16 units, the same as everywhere else in Chirp.

    private static func copied(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var out: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &out) == .success ? out : nil
    }

    private static func parameterized(_ element: AXUIElement, _ name: String, _ argument: CFTypeRef) -> CFTypeRef? {
        var out: CFTypeRef?
        return AXUIElementCopyParameterizedAttributeValue(element, name as CFString, argument, &out) == .success ? out : nil
    }

    private static func markerRange(_ element: AXUIElement, from start: CFTypeRef, to end: CFTypeRef) -> CFTypeRef? {
        parameterized(element, "AXTextMarkerRangeForUnorderedTextMarkers", [start, end] as CFArray)
    }

    /// The whole text of an element that answers through text markers.
    private static func markerText(_ element: AXUIElement) -> String? {
        guard let start = copied(element, "AXStartTextMarker"), let end = copied(element, "AXEndTextMarker"),
            let range = markerRange(element, from: start, to: end)
        else { return nil }
        return parameterized(element, "AXStringForTextMarkerRange", range) as? String
    }

    /// The cursor or selection of such an element, as a range of characters.
    private static func markerSelection(_ element: AXUIElement) -> NSRange? {
        guard let selected = copied(element, "AXSelectedTextMarkerRange"), CFGetTypeID(selected) == AXTextMarkerRangeGetTypeID() else { return nil }
        let range = selected as! AXTextMarkerRange
        func index(_ marker: AXTextMarker) -> Int? { (parameterized(element, "AXIndexForTextMarker", marker) as? NSNumber)?.intValue }
        guard let start = index(AXTextMarkerRangeCopyStartMarker(range)), let end = index(AXTextMarkerRangeCopyEndMarker(range)),
            start >= 0, end >= start
        else { return nil }
        return NSRange(location: start, length: end - start)
    }

    /// Where the text of one piece of such a page (a paragraph, a quoted block) sits in the page's whole text.
    static func range(of piece: AXUIElement, in element: AXUIElement) -> NSRange? {
        guard let markers = parameterized(element, "AXTextMarkerRangeForUIElement", piece),
            CFGetTypeID(markers) == AXTextMarkerRangeGetTypeID()
        else { return nil }
        let range = markers as! AXTextMarkerRange
        func index(_ marker: AXTextMarker) -> Int? { (parameterized(element, "AXIndexForTextMarker", marker) as? NSNumber)?.intValue }
        guard let start = index(AXTextMarkerRangeCopyStartMarker(range)), let end = index(AXTextMarkerRangeCopyEndMarker(range)),
            start >= 0, end >= start
        else { return nil }
        return NSRange(location: start, length: end - start)
    }

    /// Selects a range of characters in such an element. True when the app said yes.
    private static func selectByMarkers(_ range: NSRange, in element: AXUIElement) -> Bool {
        guard let start = parameterized(element, "AXTextMarkerForIndex", range.location as CFNumber),
            let end = parameterized(element, "AXTextMarkerForIndex", NSMaxRange(range) as CFNumber),
            let markers = markerRange(element, from: start, to: end)
        else { return false }
        return AXUIElementSetAttributeValue(element, "AXSelectedTextMarkerRange" as CFString, markers) == .success
    }

    /// Whether a field keeps its cursor as text markers and has no ordinary selection range. Such a field
    /// can say yes to an ordinary request to select or edit and then do nothing, so it is asked the marker way.
    static func usesTextMarkers(_ element: AXUIElement) -> Bool {
        copied(element, kAXSelectedTextRangeAttribute as String) == nil && copied(element, "AXSelectedTextMarkerRange") != nil
    }

    /// The whole text of a field: its value, or for a field that gives none, its text read through markers.
    static func text(of element: AXUIElement) -> String? {
        let value = stringValue(element, kAXValueAttribute)
        if let value, !value.isEmpty { return value }
        if let marked = markerText(element), !marked.isEmpty { return marked }
        return value
    }

    /// One of an element's attributes, when it is text.
    static func stringValue(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    /// A range an element reports (the selection, the characters on screen), in UTF-16 units, when the app gives one.
    static func rangeValue(_ element: AXUIElement, _ attribute: String) -> NSRange? {
        var out: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &out) == .success,
            let out, CFGetTypeID(out) == AXValueGetTypeID()
        else {
            // A field that keeps its cursor as text markers has no selection range to give.
            return attribute == (kAXSelectedTextRangeAttribute as String) ? markerSelection(element) : nil
        }
        var range = CFRange()
        return AXValueGetValue(out as! AXValue, .cfRange, &range) ? NSRange(location: range.location, length: range.length) : nil
    }

    /// Asks an element to take a range (to select it, or to scroll it into view). True when the app said yes.
    @discardableResult
    static func setRange(_ range: NSRange, _ attribute: String, in element: AXUIElement) -> Bool {
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let value = AXValueCreate(.cfRange, &cfRange) else { return false }
        let selecting = attribute == (kAXSelectedTextRangeAttribute as String)
        if selecting, usesTextMarkers(element) { return selectByMarkers(range, in: element) }
        if AXUIElementSetAttributeValue(element, attribute as CFString, value) == .success { return true }
        return selecting && selectByMarkers(range, in: element)
    }

    /// The elements directly inside another one.
    static func children(of element: AXUIElement) -> [AXUIElement] {
        var out: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &out) == .success else { return [] }
        return (out as? [AXUIElement]) ?? []
    }

    // MARK: Paste

    /// Pastes `text` over whatever is selected in the frontmost app.
    static func pasteOverSelection(_ text: String) async -> Outcome {
        guard AXIsProcessTrusted() else {
            copy(text)
            return .copiedOnly
        }
        await paste(text, menuFirst: true)
        return .pasted
    }

    /// Presses the frontmost app's own Paste command (the menu item with ⌘V, or titled "Paste").
    /// More dependable than a simulated key press, which an app can miss or remap.
    static func pasteViaMenu() -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication else { return false }
        // Where the command is was found before: press it. If that fails (the app rebuilt its menus),
        // it is looked for again below.
        let pid = front.processIdentifier
        if let known = pasteItems[pid] {
            if AXUIElementPerformAction(known, kAXPressAction as CFString) == .success { return true }
            pasteItems[pid] = nil
        }
        let app = AXUIElementCreateApplication(pid)
        var bar: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &bar) == .success, let bar,
            CFGetTypeID(bar) == AXUIElementGetTypeID()
        else { return false }
        func value(_ e: AXUIElement, _ name: String) -> CFTypeRef? {
            var out: CFTypeRef?
            AXUIElementCopyAttributeValue(e, name as CFString, &out)
            return out
        }
        var byTitle: AXUIElement?
        // The Edit menu is second or third; only the first few menus are looked through.
        for menu in children(of: bar as! AXUIElement).prefix(5) {
            for list in children(of: menu) {
                for item in children(of: list) {
                    guard (value(item, kAXEnabledAttribute) as? Bool) ?? true else { continue }
                    let key = value(item, kAXMenuItemCmdCharAttribute) as? String
                    let modifiers = (value(item, kAXMenuItemCmdModifiersAttribute) as? NSNumber)?.intValue ?? 0
                    if key == "V", modifiers == 0 {
                        let pressed = AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
                        if pressed { remember(item, for: pid) }
                        return pressed
                    }
                    if byTitle == nil, (value(item, kAXTitleAttribute) as? String) == "Paste" { byTitle = item }
                }
            }
        }
        if let byTitle {
            let pressed = AXUIElementPerformAction(byTitle, kAXPressAction as CFString) == .success
            if pressed { remember(byTitle, for: pid) }
            return pressed
        }
        return false
    }

    /// Each app's Paste command, once found, by process id.
    private static var pasteItems: [pid_t: AXUIElement] = [:]

    private static func remember(_ item: AXUIElement, for pid: pid_t) {
        // Apps that have quit are forgotten once the list grows.
        if pasteItems.count > 32 { pasteItems = pasteItems.filter { NSRunningApplication(processIdentifier: $0.key) != nil } }
        pasteItems[pid] = item
    }

    /// A copy of the clipboard: for each item on it, every type it offers with its data.
    private typealias Clipboard = [[(NSPasteboard.PasteboardType, Data)]]
    /// The user's clipboard from before a paste, until it has been put back.
    private static var held: Clipboard?
    /// The pending job that puts the clipboard back. A new paste cancels it and takes over the saved copy.
    private static var restore: Task<Void, Never>?

    /// Everything on the clipboard now, so it can be put back later.
    private static func snapshot(of pb: NSPasteboard) -> Clipboard {
        (pb.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
    }

    /// Puts a saved clipboard back in place of whatever is there.
    private static func write(_ saved: Clipboard, to pb: NSPasteboard) {
        pb.clearContents()
        guard !saved.isEmpty else { return }
        let items = saved.map { pairs -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in pairs { item.setData(data, forType: type) }
            return item
        }
        pb.writeObjects(items)
    }

    /// Pastes `text` with the clipboard and puts the user's clipboard back shortly after. `menuFirst` tries the
    /// app's own Paste menu item before the key press.
    private static func paste(_ text: String, menuFirst: Bool = false) async {
        let pb = NSPasteboard.general
        // Save everything on the clipboard so it can be put back. If the last paste has not put it back
        // yet, what is on the clipboard now is Chirp's own text: keep the copy saved then.
        restore?.cancel()
        let saved: Clipboard = held ?? snapshot(of: pb)
        held = saved
        pb.clearContents()
        pb.setString(text, forType: .string)
        // Mark as transient so clipboard managers do not keep the dictation.
        pb.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        let ourChange = pb.changeCount

        try? await Task.sleep(for: .milliseconds(40))
        if !(menuFirst && pasteViaMenu()) { sendCommand(key: keyCode(for: "v")) }
        // The words are on their way; putting the clipboard back happens behind the user's back.
        // Give the target app time to read the clipboard first. Slow apps under load need longer than a
        // fixed short delay, which is the usual cause of "pasted the old clipboard" bugs.
        restore = Task {
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            held = nil
            // Only restore if nothing else changed the clipboard in the meantime.
            guard pb.changeCount == ourChange else { return }
            write(saved, to: pb)
        }
    }

    /// Copies the frontmost app's selection with ⌘C and returns it, putting the clipboard back afterwards.
    /// Used when an app does not expose its selection through Accessibility.
    static func copySelection() async -> String? {
        let pb = NSPasteboard.general
        // If a paste has not put the clipboard back yet, what is on it now is Chirp's own text: the copy
        // saved then is the user's, and is the one to put back.
        let saved: Clipboard = held ?? snapshot(of: pb)
        let before = pb.changeCount
        sendCommand(key: keyCode(for: "c"))
        var copied: String?
        for _ in 0..<12 {
            try? await Task.sleep(for: .milliseconds(40))
            if pb.changeCount != before {
                copied = pb.string(forType: .string)
                break
            }
        }
        if pb.changeCount != before { write(saved, to: pb) }
        return (copied?.isEmpty ?? true) ? nil : copied
    }

    /// Presses a key with Command held, in the app in front.
    private static func sendCommand(key: CGKeyCode) { press(key, flags: .maskCommand) }

    /// Presses and lets go of one key in the app in front. With flags, those modifier keys count as held;
    /// without, whatever the user is really holding applies.
    private static func press(_ key: CGKeyCode, flags: CGEventFlags? = nil, source: CGEventSource? = nil) {
        let source = source ?? CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        if let flags {
            down?.flags = flags
            up?.flags = flags
        }
        down?.post(tap: .cgAnnotatedSessionEventTap)
        up?.post(tap: .cgAnnotatedSessionEventTap)
    }

    /// Key codes already worked out, by keyboard layout and letter, so the layout is not searched on every press.
    private static var keyCodes: [String: CGKeyCode] = [:]

    /// The key that types a letter in the current keyboard layout (so Dvorak and others work).
    private static func keyCode(for letter: Character) -> CGKeyCode {
        // Where the letter is on a US keyboard, for when the layout cannot be read.
        let fallback: CGKeyCode
        switch letter {
        case "c": fallback = CGKeyCode(kVK_ANSI_C)
        case "z": fallback = CGKeyCode(kVK_ANSI_Z)
        default: fallback = CGKeyCode(kVK_ANSI_V)
        }
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue() else { return fallback }
        var cacheKey: String?
        if let rawID = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) {
            let layoutID = Unmanaged<CFString>.fromOpaque(rawID).takeUnretainedValue() as String
            cacheKey = "\(layoutID)|\(letter)"
        }
        if let cacheKey, let known = keyCodes[cacheKey] { return known }
        guard let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return fallback }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        let found = data.withUnsafeBytes { ptr -> CGKeyCode in
            guard let layout = ptr.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return fallback }
            for code in 0..<128 {
                var dead: UInt32 = 0
                var chars = [UniChar](repeating: 0, count: 4)
                var length = 0
                let status = UCKeyTranslate(
                    layout, UInt16(code), UInt16(kUCKeyActionDown), 0, UInt32(LMGetKbdType()),
                    OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &length, &chars)
                if status == noErr, length == 1, chars[0] == UniChar(letter.asciiValue ?? 118) { return CGKeyCode(code) }
            }
            return fallback
        }
        if let cacheKey { keyCodes[cacheKey] = found }
        return found
    }

    /// The text just before and just after the cursor in the focused field, when the app says.
    static func cursorContext() -> (before: String, after: String)? {
        guard AXIsProcessTrusted(), let element = focusedElement(), let value = text(of: element),
            let range = rangeValue(element, kAXSelectedTextRangeAttribute)
        else { return nil }
        let ns = value as NSString
        guard range.location >= 0, range.location + range.length <= ns.length else { return nil }
        let start = max(0, range.location - 40)
        let end = range.location + range.length
        return (ns.substring(with: NSRange(location: start, length: range.location - start)),
                ns.substring(with: NSRange(location: end, length: min(5, ns.length - end))))
    }

    /// Selects everything in a text field through Accessibility.
    static func selectAll(in element: AXUIElement) -> Bool {
        guard let value = text(of: element) else { return false }
        return setRange(NSRange(location: 0, length: (value as NSString).length), kAXSelectedTextRangeAttribute, in: element)
    }

    /// Undoes the last change in the app in front (⌘Z), for taking back a paste that went wrong.
    static func pressUndo() {
        guard AXIsProcessTrusted() else { return }
        sendCommand(key: keyCode(for: "z"))
    }

    /// Presses the left or right arrow `times` times in the app in front, with Shift held to select.
    static func pressArrow(right: Bool, shift: Bool, times: Int) {
        guard AXIsProcessTrusted(), times > 0 else { return }
        let source = CGEventSource(stateID: .combinedSessionState)
        let key = CGKeyCode(right ? kVK_RightArrow : kVK_LeftArrow)
        // Arrow keys carry these two flags when a person presses them; some apps look for them.
        let flags: CGEventFlags = shift ? [.maskShift, .maskNumericPad, .maskSecondaryFn] : [.maskNumericPad, .maskSecondaryFn]
        for _ in 0..<times {
            press(key, flags: flags, source: source)
            usleep(2_000)
        }
    }

    /// Presses Return in the frontmost app (for a spoken "press enter").
    static func pressReturn() {
        guard AXIsProcessTrusted() else { return }
        press(CGKeyCode(kVK_Return))
    }

    // MARK: Reading the selection (used by Write)

    /// The selected text in the frontmost app, read through Accessibility.
    static func selectedText() -> String? {
        guard let element = focusedElement() else { return nil }
        if let s = stringValue(element, kAXSelectedTextAttribute), !s.isEmpty { return s }
        // A field that answers through text markers: the characters of its selection.
        guard let range = markerSelection(element), range.length > 0, let whole = markerText(element) as NSString?,
            NSMaxRange(range) <= whole.length
        else { return nil }
        return whole.substring(with: range)
    }
}
