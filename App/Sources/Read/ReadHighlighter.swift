import AppKit
import ChirpCore
import SwiftUI

/// Marks, in the app the text came from, the sentence being read and the word being spoken. It works
/// wherever the app can say where its text is on screen: the same question the writing checks ask to
/// place their underlines.
@MainActor
final class ReadHighlighter {
    /// Where the text being read lives: a text field, or the pieces of text of a page.
    private enum Source {
        case field(AXUIElement)
        case pieces([UnderlineController.TextRun], String)
    }

    private var source: Source?
    /// Where the last sentence was found in the source text; the same sentence is looked for again from here.
    private var cursor = 0
    /// Where the last sentence found ends in the source text; the next sentence is looked for from here,
    /// so a sentence that repeats the one before it is not found on top of it.
    private var lastEnd = 0
    /// The number of the last sentence found, when the caller gave one. It tells which way reading moved.
    private var lastIndex: Int?
    /// Where the read text begins in the source; a step back to an earlier sentence is looked for from here.
    private var base = 0
    /// Where the sentence being read sits in the source text. Nil when it could not be found there.
    private var sentence: NSRange?
    /// The words of the sentence being read, as places in the sentence itself (what the reader names a
    /// word by), and where each was found in the source text. A word that was not found there has no
    /// place and is not marked: nothing is counted from the start of the sentence (`ReadMarks`).
    private var sentenceWords: [NSRange] = []
    private var sourceWords: [NSRange?] = []
    /// Whether the page is moved to keep up, and why not when it is not (`ReadFollow`).
    private var follow = ReadFollow()
    /// Each piece's text as the app itself counts its characters, asked for once a piece (by its place in
    /// the source). `.some(nil)` is a piece whose app would not say.
    private var counted: [Int: String?] = [:]
    /// For the log and the debug state: sentences looked for and not found, words marked and left unmarked,
    /// and marks moved because the app counts a piece's characters differently.
    private(set) var tally = (sentences: 0, notFound: 0, words: 0, unmarked: 0, settled: 0, requests: 0, rejected: 0)
    /// The word being spoken by its number among the sentence's words, for the words beside it.
    private var wordPlace: Int?
    /// Whether the app's box for a word is around that word, found once a word. A word whose box
    /// could not be measured at all is not kept, so it is tried again at the next drawing.
    private var checkedWord: (range: NSRange, verdict: WordBox.Verdict)?
    /// Whether the last word mark was moved because the app counts a piece differently; such a box
    /// is not checked against its neighbours, which are measured in the other count.
    private var wordMoved = false
    /// Word boxes written to the log in this read, and when the last was (a few per read, so a real
    /// page can show what the app answered without filling the log).
    private var boxLogs = 0
    private var boxLoggedAt = Date.distantPast
    /// Where the word being spoken sits in the source text.
    private var word: NSRange?
    /// The clear, click-through window laid over every screen that the marks are drawn in.
    private var window: NSPanel?
    private let model = ReadHighlightModel()
    /// The app the text is in. The marks are only shown while it is in front.
    private var owner: pid_t?
    /// Redraws the marks a few times a second for as long as text is being followed (see `follow`).
    private var timer: Timer?
    /// A text field's whole text, as it was when the sentence being read was looked for.
    private var fieldText = ""
    /// The pieces of text inside a web editor's field, each with its place in `fieldText`. Asking the
    /// other app for them is slow, so they are kept for the sentence and not asked for at every redraw.
    private var fieldRuns: [UnderlineController.TextRun]?
    /// When `fieldRuns` was last asked for.
    private var runsMeasured = Date.distantPast

    /// True while there is text in another app to mark.
    var isActive: Bool { source != nil }

    /// Starts following text read from a text field, beginning at `start` in the field's text.
    func begin(field: AXUIElement, at start: Int) {
        begin(.field(field), at: max(0, start))
    }

    /// Starts following text gathered from a page, piece by piece.
    func begin(pieces: [UnderlineController.TextRun], text: String) {
        begin(.pieces(pieces, text), at: 0)
    }

    /// Starts afresh on a new source: nothing found yet, nothing kept from the text followed before.
    private func begin(_ source: Source, at start: Int) {
        self.source = source
        cursor = start
        lastEnd = start
        lastIndex = nil
        base = start
        fieldText = ""
        fieldRuns = nil
        pageClip = nil
        pageClipAt = .distantPast
        scrolledAt = .distantPast
        follow = ReadFollow()
        counted = [:]
        sentenceWords = []
        sourceWords = []
        tally = (0, 0, 0, 0, 0, 0, 0)
        checkedWord = nil
        wordPlace = nil
        boxLogs = 0
        watch()
        sentence = nil
        word = nil
    }

    /// Keeps the marks where the words are (the page scrolls, the window moves) and puts them away while
    /// another app is in front, also while reading is paused. This timer is the one place the marks are
    /// measured again without the sentence or word having changed.
    private func watch() {
        owner = NSWorkspace.shared.frontmostApplication?.processIdentifier
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.source != nil else { return }
                if NSWorkspace.shared.frontmostApplication?.processIdentifier != self.owner {
                    self.window?.orderOut(nil)
                } else if self.sentence != nil {
                    self.draw()
                    // Whether the page should keep following is judged here, between sentences: the reader
                    // scrolling the sentence out of view stops it, scrolling back starts it again. A sentence
                    // that has not come into view since reading reached it is not the reader's doing (a
                    // picture above it still loading, a page that scrolls slowly): it is asked for again.
                    if self.follow.looked(inView: !self.model.sentence.isEmpty, sinceRequest: Date().timeIntervalSince(self.scrolledAt)),
                        Self.followsReading, let sentence = self.sentence
                    {
                        self.scrolledAt = Date()
                        self.tally.requests += 1
                        self.wheel(to: sentence, retry: true)
                    }
                }
            }
        }
    }

    /// Stops following the text and takes the marks off the screen.
    func end() {
        timer?.invalidate()
        timer = nil
        source = nil
        sentence = nil
        word = nil
        fieldText = ""
        fieldRuns = nil
        model.sentence = []
        model.word = nil
        window?.orderOut(nil)
    }

    /// The sentence now being read. It is found again in the source text, which may have been tidied
    /// (line breaks joined, spaces collapsed) before it was read out.
    ///
    /// `index` is the sentence's number in what is being read. With it, a sentence after the last one is
    /// looked for past the end of that one (so the same words twice in a row are found twice), and an
    /// earlier sentence is looked for before it, nearest first. Without it, the search starts where the
    /// last sentence was found.
    func show(sentence text: String, index: Int? = nil) {
        guard let source else { return }
        // "Mark the sentence and word being read" is off: nothing is looked for and nothing is drawn. The
        // sentence is not remembered either, so turning the setting on shows marks from the next sentence.
        guard ReadingChoices.marks else { return hide() }
        let whole: String
        switch source {
        case .field(let element):
            whole = TextInserter.text(of: element) ?? ""
            // The pieces are asked for again only when a drawing needs them.
            fieldText = whole
            fieldRuns = nil
        case .pieces(_, let joined): whole = joined
        }
        let wanted = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else { return clear() }
        // The text may have got shorter since the last sentence (the user deleted some): stay inside it.
        let length = (whole as NSString).length
        let start = min(base, length)
        let here = max(start, min(cursor, length))
        let after = max(here, min(lastEnd, length))
        // Which way reading moved since the last sentence found: on (above 0), back (below 0), or the
        // same sentence again or not known (0).
        var step = 0
        if let index, let lastIndex { step = index - lastIndex }
        var hit: (range: NSRange, exact: Bool)?
        var from = start
        if step < 0 {
            // Going back: the nearest place before the last sentence found.
            hit = ReadMarks.find(wanted, in: whole, range: NSRange(location: start, length: here - start), backwards: true)
        } else {
            from = step > 0 ? after : here
            hit = ReadMarks.find(wanted, in: whole, range: NSRange(location: from, length: length - from), backwards: false)
        }
        if hit == nil, step < 0 || from > start {
            // Not where it was expected (the text changed, or reading jumped): anywhere in what is being read.
            hit = ReadMarks.find(wanted, in: whole, range: NSRange(location: start, length: length - start), backwards: false)
        }
        tally.sentences += 1
        guard let hit else {
            tally.notFound += 1
            Log.write("read", "marks: sentence \(index.map(String.init) ?? "?") was not found in the text it came from (\(wanted.count) characters)")
            return clear()
        }
        let found = hit.range
        sentence = found
        // Each word is found again inside the sentence, in order: a link or bold in the middle of it puts
        // extra spaces in the source, and a word's place counted from the start of the sentence would
        // then be a few characters out.
        sentenceWords = ReadingText.wordRanges(wanted)
        sourceWords = ReadMarks.words(of: wanted, in: whole, found: found)
        cursor = found.location
        lastEnd = NSMaxRange(found)
        lastIndex = index
        word = nil
        draw()
        // Keep up with the reading: when this sentence is not in view, the page is moved to it. If the
        // reader has scrolled away to look at something else, it is left where it is.
        if follow.reached(inView: !model.sentence.isEmpty), Self.followsReading {
            scrolledAt = Date()
            tally.requests += 1
            bringIntoView(found)
        }
    }

    /// Settings › Reading › "Scroll to follow the reading".
    private static var followsReading: Bool { UserDefaults.standard.object(forKey: ReadingChoices.followKey) as? Bool ?? true }

    /// When the page was last asked to scroll to the sentence being read.
    private var scrolledAt = Date.distantPast
    /// The part of the screen a page's text shows through, and when it was last measured.
    private var pageClip: CGRect?
    private var pageClipAt = Date.distantPast

    /// The part of the screen the page holding `element` shows through: its scrolling areas, cut down to
    /// its window. A web page's own box is as tall as the whole page, so text scrolled out of sight still
    /// reports a position, above or below the window; this is what tells it apart from text in view.
    private static func viewport(around element: AXUIElement) -> CGRect? {
        var frame: CGRect?
        var current = element
        for _ in 0..<40 {
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parent) == .success, let parent,
                CFGetTypeID(parent) == AXUIElementGetTypeID()
            else { break }
            current = parent as! AXUIElement
            let role = TextInserter.stringValue(current, kAXRoleAttribute) ?? ""
            guard role == (kAXScrollAreaRole as String) || role == (kAXWindowRole as String),
                let outer = UnderlineController.frame(of: current)
            else { continue }
            frame = frame.map { $0.intersection(outer) } ?? outer
            if role == (kAXWindowRole as String) { break }
        }
        return frame
    }

    /// The pieces of text inside a web editor's field: the ones kept for this sentence, or asked for
    /// again when there are none yet or `fresh` is true.
    private func runs(in element: AXUIElement, fresh: Bool = false) -> [UnderlineController.TextRun] {
        if !fresh, let fieldRuns { return fieldRuns }
        let found = UnderlineController.textRuns(in: element, text: fieldText)
        fieldRuns = found
        runsMeasured = Date()
        return found
    }

    /// Asks the other app to scroll so this part of the text shows, then draws the marks again.
    private func bringIntoView(_ range: NSRange) {
        guard let source else { return }
        switch source {
        case .field(let element):
            // A text view scrolls when told which characters to show.
            var visible = CFRange(location: range.location, length: range.length)
            if let value = AXValueCreate(.cfRange, &visible),
                AXUIElementSetAttributeValue(element, kAXVisibleCharacterRangeAttribute as CFString, value) == .success,
                !rects(for: range).isEmpty
            {
                break
            }
            // A web editor scrolls a piece of its text into view when asked.
            for run in runs(in: element) where NSIntersectionRange(run.range, range).length > 0 {
                AXUIElementPerformAction(run.element, "AXScrollToVisible" as CFString)
                break
            }
            // Scrolling can make the editor rebuild its pieces, so the kept ones are asked for again.
            fieldRuns = nil
        case .pieces(let runs, _):
            for run in runs where NSIntersectionRange(run.range, range).length > 0 {
                AXUIElementPerformAction(run.element, "AXScrollToVisible" as CFString)
                break
            }
        }
        draw()
        // Some pages do not scroll when asked this way (Mail shows a message at its full height inside
        // a scrolling list, and the request stops at the message). If the sentence is still out of view
        // a moment later, the page is scrolled the way a person would, with the wheel.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, self.sentence == range, self.rects(for: range).isEmpty else { return }
            self.wheel(to: range, retry: true)
        }
    }

    /// Scrolls the page with the wheel until the sentence sits a third of the way down what is showing.
    /// If the page moved the wrong way (the wheel's direction is a setting), it is turned once.
    private func wheel(to range: NSRange, retry: Bool, flip: Bool = false) {
        guard let source, NSWorkspace.shared.frontmostApplication?.processIdentifier == owner,
            let at = rects(for: range, clipped: false).first
        else { return }
        let view: CGRect?
        switch source {
        case .field(let element): view = UnderlineController.visibleFrame(of: element)
        case .pieces: view = pageClip
        }
        guard let view, view.height > 40 else { return }
        let off = at.midY - (view.minY + view.height / 3)
        guard abs(off) > 1, abs(off) < 20_000 else { return }
        let amount = Int32((flip ? off : -off).rounded())
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: amount, wheel2: 0, wheel3: 0) else { return }
        event.location = CGPoint(x: view.midX, y: view.midY)
        event.post(tap: .cghidEventTap)
        scrolledAt = Date()
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, self.sentence == range else { return }
            self.pageClipAt = .distantPast
            if let now = self.rects(for: range, clipped: false).first, retry,
                abs(now.midY - (view.minY + view.height / 3)) > abs(off) + 1
            {
                // Further away than before: the wheel runs the other way on this Mac.
                self.wheel(to: range, retry: false, flip: !flip)
            }
            self.draw()
        }
    }

    /// The word being spoken, as a range within the sentence that was read out.
    func show(word range: NSRange?) {
        guard ReadingChoices.marks else { return hide() }
        // The word by its number in the sentence, then where that word was found in the source.
        let place = range.flatMap { r in sentenceWords.firstIndex { $0 == r } ?? sentenceWords.firstIndex { NSLocationInRange(r.location, $0) } }
        guard sentence != nil, let place, let absolute = sourceWords[safe: place] ?? nil else {
            if range != nil, sentence != nil { tally.unmarked += 1 }
            if word != nil {
                word = nil
                draw()
            }
            return
        }
        guard absolute != word else { return }
        tally.words += 1
        word = absolute
        wordPlace = place
        draw()
    }

    /// Takes the marks off the screen while the setting for them is off. The text is still followed.
    private func hide() {
        guard sentence != nil || window?.isVisible == true else { return }
        clear()
        window?.orderOut(nil)
    }

    /// Forgets the sentence and word and empties the marks (used when the sentence cannot be found).
    private func clear() {
        sentence = nil
        word = nil
        sentenceWords = []
        sourceWords = []
        model.sentence = []
        model.word = nil
    }

    /// Where the word being spoken is on screen. Its place in the source is first checked against the
    /// app's own count of the piece it is in: some apps hand a piece's text over one way and count its
    /// characters another, and a mark placed by the first then covers the end of one word and the start
    /// of the next. When the two differ the mark is moved onto the word; when the
    /// word is not there at all, it is left out. An app that will not say how it counts is trusted as before.
    private func wordRects(for range: NSRange) -> [CGRect] {
        wordMoved = false
        guard let source else { return [] }
        let whole: NSString
        let pieces: [UnderlineController.TextRun]
        switch source {
        case .pieces(let runs, let joined):
            pieces = runs
            whole = joined as NSString
        case .field(let element):
            // A plain text field answers for its own characters; only a web editor's pieces are in question.
            let direct = UnderlineController.lineBounds(of: range, in: element)
            if !direct.isEmpty, !direct.contains(where: { $0.width <= 1 || $0.height <= 1 }) { return rects(for: range) }
            pieces = runs(in: element)
            whole = fieldText as NSString
        }
        guard NSMaxRange(range) <= whole.length,
            let at = pieces.firstIndex(where: { NSIntersectionRange($0.range, range).length == range.length })
        else { return rects(for: range) }
        let run = pieces[at]
        if counted[run.range.location] == nil { counted[run.range.location] = .some(Self.ownText(of: run.element)) }
        guard let own = counted[run.range.location] ?? nil else { return rects(for: range) }
        let local = NSRange(location: range.location - run.range.location, length: range.length)
        guard let settled = ReadMarks.settled(whole.substring(with: range), at: local, in: own) else {
            tally.unmarked += 1
            return []
        }
        if settled == local { return rects(for: range) }
        wordMoved = true
        if tally.settled == 0 {
            Log.write("read", "marks: this app counts a piece of text differently from the text it gives (a word was \(settled.location - local.location) characters from where it was worked out); marks are moved onto the words")
        }
        tally.settled += 1
        let moved = UnderlineController.runBounds(of: settled, in: [UnderlineController.TextRun(range: NSRange(location: 0, length: (own as NSString).length), element: run.element)])
        let visible = pageClip
        return moved.filter { r in
            r.width > 1 && r.height > 1 && r.width < 4000 && r.height < 400 && (visible.map { $0.insetBy(dx: -2, dy: -2).contains(r) } ?? true)
        }
    }

    /// Whether the app's box for the word being spoken is around that word. The box
    /// of the whole word is asked for in one go and compared with the words beside it and the width its
    /// letters take on the line (`WordBox`). When it fails, no word mark is drawn; the sentence mark stays.
    private func boxLooksRight(_ range: NSRange) -> Bool {
        if let checkedWord, checkedWord.range == range { return checkedWord.verdict == .ok }
        guard let place = wordPlace, sourceWords[safe: place] == range else { return true }
        let result = WordBox.check(place: place, words: sourceWords) { [unowned self] r in self.rects(for: r, clipped: false) }
        if result.verdict != .missing { checkedWord = (range, result.verdict) }
        if result.verdict != .ok, result.verdict != .missing { tally.rejected += 1 }
        logBox(range, result)
        // A word that could not be measured is drawn as before, from `wordRects`.
        return result.verdict == .ok || result.verdict == .missing
    }

    /// Writes what was asked and what the app answered for a word: the first three words of each read and
    /// every word whose box was not drawn, at most one line a second and 25 a read (or every word, with
    /// the debug switch). Enough for one real read to show whether ligatures put a word's box in the wrong place.
    private func logBox(_ range: NSRange, _ result: WordBox.Result) {
        let wrong = result.verdict != .ok
        guard (boxLogs < 25 && (boxLogs < 3 || (wrong && Date().timeIntervalSince(boxLoggedAt) > 1))) else { return }
        boxLogs += 1
        boxLoggedAt = Date()
        let app = owner.flatMap { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier } ?? "?"
        var text = ""
        var piece = ""
        switch source {
        case .some(.pieces(let runs, let joined)):
            if NSMaxRange(range) <= (joined as NSString).length { text = (joined as NSString).substring(with: range) }
            if let at = runs.firstIndex(where: { NSIntersectionRange($0.range, range).length > 0 }) {
                piece = " (piece \(at), at \(range.location - runs[at].range.location))"
            }
        case .some(.field):
            if NSMaxRange(range) <= (fieldText as NSString).length { text = (fieldText as NSString).substring(with: range) }
        case .none: break
        }
        func r(_ b: CGRect?) -> String { b.map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" } ?? "none" }
        let shown = result.verdict == .ok || result.verdict == .missing ? "drawn" : "not drawn"
        Log.write("read", "marks: word box in \(app): \(text.count) characters asked \(range.location)+\(range.length)\(piece) -> \(r(result.box)); before \(r(result.previous)), after \(r(result.next)), three words \(r(result.span)): \(result.verdict.rawValue), \(shown)")
    }

    /// A piece's text as its app counts it: what the app returns for the piece's whole range of characters.
    private static func ownText(of element: AXUIElement) -> String? {
        var count: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXNumberOfCharactersAttribute as CFString, &count) == .success,
            let n = (count as? NSNumber)?.intValue, n > 0
        else { return nil }
        var whole = CFRange(location: 0, length: n)
        guard let value = AXValueCreate(.cfRange, &whole) else { return nil }
        var out: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString, value, &out) == .success
        else { return nil }
        return out as? String
    }

    /// Where a range of the source text is on screen, one box per line, as the other app reports it
    /// (top-left origin). Boxes that are scrolled out of view or make no sense are left out.
    private func rects(for range: NSRange, clipped: Bool = true) -> [CGRect] {
        guard let source else { return [] }
        var pieces: [CGRect]
        var visible: CGRect?
        switch source {
        case .field(let element):
            pieces = UnderlineController.lineBounds(of: range, in: element)
            // Web editors answer for the pieces of text inside the field, not the field.
            if pieces.isEmpty || pieces.contains(where: { $0.width <= 1 || $0.height <= 1 }) {
                pieces = UnderlineController.runBounds(of: range, in: runs(in: element))
                // Nothing from the kept pieces: the editor may have rebuilt them (some do when the page
                // scrolls). They are asked for again, but no more than once a second.
                if pieces.isEmpty, Date().timeIntervalSince(runsMeasured) > 1 {
                    pieces = UnderlineController.runBounds(of: range, in: runs(in: element, fresh: true))
                }
            }
            visible = UnderlineController.visibleFrame(of: element)
        case .pieces(let runs, _):
            pieces = UnderlineController.runBounds(of: range, in: runs)
            // Measured again now and then, since the window can be moved or resized while reading.
            if Date().timeIntervalSince(pageClipAt) > 0.5,
                let run = runs.first(where: { NSIntersectionRange($0.range, range).length > 0 }) ?? runs.first
            {
                pageClip = Self.viewport(around: run.element)
                pageClipAt = Date()
            }
            visible = pageClip
        }
        return pieces.filter { r in
            r.width > 1 && r.height > 1 && r.width < 4000 && r.height < 400 && (!clipped || (visible.map { $0.insetBy(dx: -2, dy: -2).contains(r) } ?? true))
        }
    }

    /// Measures where the sentence and word are now and shows the marks there, making the overlay window
    /// the first time. Hides the window when the sentence is not in view, and does not measure at all
    /// while another app is in front (the marks are not shown then, and asking would be wasted work).
    private func draw() {
        guard let sentence else { return }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == owner else {
            window?.orderOut(nil)
            return
        }
        let screenHeight = NSScreen.screens.first?.frame.height ?? 0
        func flipped(_ r: CGRect) -> CGRect { CGRect(x: r.minX, y: screenHeight - r.maxY, width: r.width, height: r.height) }
        let lines = rects(for: sentence).map(flipped)
        var spoken = word.flatMap { wordRects(for: $0).first }.map(flipped)
        if let word, spoken != nil, !wordMoved, !boxLooksRight(word) { spoken = nil }
        guard !lines.isEmpty else {
            model.sentence = []
            model.word = nil
            window?.orderOut(nil)
            return
        }
        let frame = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }
        let w = window ?? {
            let w = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            w.isFloatingPanel = true
            w.hidesOnDeactivate = false
            w.becomesKeyOnlyIfNeeded = true
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false
            w.ignoresMouseEvents = true
            w.level = .floating
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: ReadHighlightView(model: model))
            return w
        }()
        window = w
        if w.frame != frame { w.setFrame(frame, display: false) }
        model.origin = frame.origin
        model.height = frame.height
        model.sentence = lines
        model.word = spoken
        w.orderFrontRegardless()
    }
}

/// What the overlay draws: the boxes behind the sentence and the word, in screen coordinates
/// (bottom-left origin), and the overlay window's own place so they can be drawn inside it.
@MainActor
@Observable
final class ReadHighlightModel {
    /// One box per line of the sentence being read.
    var sentence: [CGRect] = []
    var word: CGRect?
    /// The overlay window's bottom-left corner and height, which cover all screens.
    var origin = CGPoint.zero
    var height: CGFloat = 0
}

/// A soft amber band behind the sentence and a stronger one behind the word. Drawn over another app's
/// page, where a tint (not a solid block) keeps the words underneath readable in light and dark.
struct ReadHighlightView: View {
    let model: ReadHighlightModel

    var body: some View {
        let origin = model.origin, height = model.height, sentence = model.sentence, word = model.word
        Canvas { ctx, _ in
            func place(_ r: CGRect) -> CGRect {
                CGRect(x: r.minX - origin.x - 2, y: height - (r.maxY - origin.y) - 1, width: r.width + 4, height: r.height + 2)
            }
            for r in sentence {
                ctx.fill(Path(roundedRect: place(r), cornerRadius: 4), with: .color(Color.amber.opacity(0.22)))
            }
            if let w = word {
                ctx.fill(Path(roundedRect: place(w), cornerRadius: 4), with: .color(Color.amber.opacity(0.42)))
            }
        }
        .accessibilityHidden(true)
    }
}
