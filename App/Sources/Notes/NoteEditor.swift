import AppKit
import ChirpCore
import SwiftUI

// A note's editor: Markdown shown formatted as it is typed, in the perch and full size in the
// Library. The text
// stays plain Markdown in one NSTextView; patterns style it in place after every change; the marks
// (`#`, `**`, `` ` ``, fences) keep their characters but are drawn only in the paragraph being edited,
// and are given no glyphs everywhere else. Writing checks are the checked editor's (CheckedTextEditor),
// left off code and marks.

extension NSAttributedString.Key {
    /// On a mark's characters: true while it is hidden (not in the paragraph being edited).
    static let noteMark = NSAttributedString.Key("chirp.noteMark")
    /// On a list point's "-", "*" or "+": drawn as a bullet away from the paragraph being edited.
    static let noteBullet = NSAttributedString.Key("chirp.noteBullet")
    /// On a code block's characters (fences included): the block's range, for its background.
    static let noteCodeBlock = NSAttributedString.Key("chirp.noteCodeBlock")
    /// On code inside a line.
    static let noteCode = NSAttributedString.Key("chirp.noteCode")
    /// On the backticks around code in a line: hidden by being drawn clear, so the code's fill keeps a
    /// little room either side.
    static let noteCodeMark = NSAttributedString.Key("chirp.noteCodeMark")
}

/// The sizes and colours a note is drawn with. The perch's note is a little smaller than the Library's.
struct NoteLook {
    var size: CGFloat
    var inset: NSSize

    static let perch = NoteLook(size: 13.5, inset: NSSize(width: 14, height: 8))
    static let page = NoteLook(size: 15, inset: NSSize(width: 4, height: 10))

    var body: NSFont { .systemFont(ofSize: size) }
    var code: NSFont { .monospacedSystemFont(ofSize: size - 1.5, weight: .regular) }
    func heading(_ level: Int) -> NSFont {
        switch level {
        case 1: .systemFont(ofSize: size + 4.5, weight: .semibold)
        case 2: .systemFont(ofSize: size + 2.5, weight: .semibold)
        default: .systemFont(ofSize: size + 1, weight: .semibold)
        }
    }
    static let ink = NSColor(named: "Ink") ?? .labelColor
    static let marks = NSColor.tertiaryLabelColor
    static let quiet = NSColor.secondaryLabelColor
    static let codeFill = NSColor.labelColor.withAlphaComponent(0.07)
}

/// Draws the rounded fill behind code blocks and code in a line.
final class NoteLayoutManager: PatternLayoutManager {
    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage, let container = textContainers.first else { return }
        let chars = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        NoteLook.codeFill.setFill()
        // A block: one box from its first line to its last, the width of the text.
        var seen = Set<Int>()
        storage.enumerateAttribute(.noteCodeBlock, in: chars) { value, _, _ in
            guard let block = (value as? NSValue)?.rangeValue, seen.insert(block.location).inserted else { return }
            var visible = block
            if storage.attribute(.noteMark, at: block.location, effectiveRange: nil) as? Bool == true {
                // The opening fence is hidden: the box starts at the code.
                let first = (storage.string as NSString).lineRange(for: NSRange(location: block.location, length: 0))
                visible = NSRange(location: NSMaxRange(first), length: max(0, NSMaxRange(block) - NSMaxRange(first)))
            }
            guard visible.length > 0 else { return }
            let glyphs = glyphRange(forCharacterRange: visible, actualCharacterRange: nil)
            var box = boundingRect(forGlyphRange: glyphs, in: container)
            box.origin.x = 0
            box.size.width = container.size.width - container.lineFragmentPadding
            box = box.insetBy(dx: 0, dy: -4).offsetBy(dx: origin.x, dy: origin.y)
            NSBezierPath(roundedRect: box, xRadius: 7, yRadius: 7).fill()
        }
        storage.enumerateAttribute(.noteCode, in: chars) { value, range, _ in
            guard value != nil else { return }
            let glyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: container) { rect, _ in
                let box = rect.insetBy(dx: -3, dy: 0).offsetBy(dx: origin.x, dy: origin.y)
                NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill()
            }
        }
    }
}

/// The text view of a note. It knows how to take dictated words at its cursor, continues a list on
/// Return, and closes on Escape.
final class NoteTextView: NSTextView {
    var onEscape: (() -> Void)?
    /// The note editor that has the keyboard, if any: dictated words go there (see `DictationController`).
    nonisolated(unsafe) static weak var focused: NoteTextView?

    override func becomeFirstResponder() -> Bool {
        let took = super.becomeFirstResponder()
        if took { Self.focused = self }
        return took
    }

    override func resignFirstResponder() -> Bool {
        let gave = super.resignFirstResponder()
        if gave, Self.focused === self { Self.focused = nil }
        return gave
    }

    /// True while this editor is where typing goes: its window has the keyboard and it is first in it.
    var hasKeyboard: Bool { window?.isKeyWindow == true && window?.firstResponder === self }

    /// Called just before each change that is dictated.
    var onDictated: (() -> Void)?

    /// Puts dictated words at the cursor, spaced and capitalised for what is around them, as Dictate does
    /// in another app. Undo takes them out again.
    func insertDictated(_ text: String) {
        let ns = string as NSString
        let at = selectedRange()
        let before = ns.substring(to: at.location)
        let after = ns.substring(from: NSMaxRange(at))
        let words = Insertion.adapt(text, before: String(before.suffix(200)), after: String(after.prefix(200)))
        // Said before the change, so the change is known as dictated when it is passed on.
        onDictated?()
        guard !words.isEmpty, shouldChangeText(in: at, replacementString: words) else { return }
        replaceCharacters(in: at, with: words)
        didChangeText()
        setSelectedRange(NSRange(location: at.location + (words as NSString).length, length: 0))
        scrollRangeToVisible(selectedRange())
    }

    override func cancelOperation(_ sender: Any?) {
        if let onEscape { onEscape() } else { super.cancelOperation(sender) }
    }

    /// The line's text from its start up to the cursor.
    private func lineBeforeCursor() -> (line: NSRange, text: String) {
        let ns = string as NSString
        let at = selectedRange()
        let line = ns.lineRange(for: NSRange(location: at.location, length: 0))
        return (line, ns.substring(with: NSRange(location: line.location, length: at.location - line.location)))
    }

    /// Return in a list point starts the next one; Return on an empty point ends the list (as Apple
    /// Notes does; the rule is `NoteLists`).
    override func insertNewline(_ sender: Any?) {
        let at = selectedRange()
        guard at.length == 0 else { return super.insertNewline(sender) }
        let (line, before) = lineBeforeCursor()
        switch NoteLists.onReturn(lineBefore: before) {
        case .plain:
            super.insertNewline(sender)
        case .endList(let length):
            // The marker goes; the line is left blank and the list has ended.
            let marker = NSRange(location: line.location, length: length)
            if shouldChangeText(in: marker, replacementString: "") {
                replaceCharacters(in: marker, with: "")
                didChangeText()
                setSelectedRange(NSRange(location: line.location, length: 0))
            }
        case .next(let marker):
            insertText("\n" + marker, replacementRange: at)
        }
    }

    /// A marker typed at the start of a point that already has the continued one replaces it ("- " on
    /// "- " stays "- ", "1. " on "- " makes it numbered), rather than giving "- - ".
    override func insertText(_ text: Any, replacementRange: NSRange) {
        let typed = (text as? String) ?? (text as? NSAttributedString)?.string ?? ""
        let at = replacementRange.location == NSNotFound ? selectedRange() : replacementRange
        if at.length == 0, at == selectedRange() {
            let (line, before) = lineBeforeCursor()
            if let whole = NoteLists.onType(typed, lineBefore: before) {
                let range = NSRange(location: line.location, length: at.location - line.location)
                return super.insertText(whole, replacementRange: range)
            }
        }
        super.insertText(text, replacementRange: replacementRange)
    }
}

/// The editor as a SwiftUI view. `text` is the note's Markdown; `onEdit` is told of each change and
/// whether it was typed or dictated.
struct NoteEditor: NSViewRepresentable {
    @Binding var text: String
    var look: NoteLook = .page
    /// Writing checks run in the note (Settings › Notes › Check writing in notes, and Writing checks on).
    var checks: Bool = true
    /// While right ⌥ is held over this note: a small listening mark at the cursor.
    var listening = false
    var level: Double = 0
    /// Takes the keyboard as soon as it is shown.
    var focusOnAppear = false
    var identifier = "note.editor"
    var onEdit: (_ dictated: Bool) -> Void = { _ in }
    var onEscape: (() -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let storage = NSTextStorage()
        let layout = NoteLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        let view = NoteTextView(frame: .zero, textContainer: container)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.minSize = NSSize(width: 0, height: 0)
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        let scroll = NSScrollView()
        scroll.documentView = view
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        view.delegate = context.coordinator
        layout.delegate = context.coordinator
        view.font = look.body
        view.textColor = NoteLook.ink
        view.textContainerInset = look.inset
        view.isRichText = false
        view.allowsUndo = true
        view.drawsBackground = false
        view.typingAttributes = [.font: look.body, .foregroundColor: NoteLook.ink]
        // Chirp does the checking; the system's red dots would double up. Its own models do the rest.
        view.isContinuousSpellCheckingEnabled = false
        view.isGrammarCheckingEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.writingToolsBehavior = .none
        view.setAccessibilityIdentifier(identifier)
        view.setAccessibilityLabel("Note")
        view.onEscape = onEscape
        view.onDictated = { [weak coordinator = context.coordinator] in coordinator?.dictatedPending = true }
        view.string = text
        context.coordinator.textView = view
        context.coordinator.restyle()
        let click = NSClickGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.clicked(_:)))
        click.delaysPrimaryMouseButtonEvents = false
        view.addGestureRecognizer(click)
        context.coordinator.scheduleCheck(immediately: true)
        if focusOnAppear {
            DispatchQueue.main.async {
                view.window?.makeFirstResponder(view)
                view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
            }
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NoteTextView else { return }
        let checksWere = context.coordinator.parent.checks
        context.coordinator.parent = self
        view.onEscape = onEscape
        if view.string != text {
            view.string = text
            view.undoManager?.removeAllActions()
            context.coordinator.restyle()
            context.coordinator.scheduleCheck(immediately: true)
        }
        if checksWere != checks { context.coordinator.scheduleCheck(immediately: true) }
        context.coordinator.showListening(listening, level: level)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate, NSLayoutManagerDelegate {
        var parent: NoteEditor
        weak var textView: NoteTextView?
        /// The editor on screen, for test hooks.
        static weak var current: Coordinator?
        /// The last change came from dictation.
        var dictatedPending = false
        /// What the checks found, and the spans the last restyle found.
        private(set) var issues: [WritingIssue] = []
        private var unchecked: [NSRange] = []
        /// The paragraph whose marks are showing.
        private var active = NSRange(location: NSNotFound, length: 0)
        private var pending: Task<Void, Never>?
        private var popover: NSPopover?
        private var chip: NSHostingView<ListeningChip>?

        init(_ parent: NoteEditor) {
            self.parent = parent
            super.init()
            Self.current = self
        }

        // MARK: Styling

        /// Styles the whole note from its Markdown. Notes are short, so styling only the changed paragraph is not needed.
        func restyle() {
            guard let view = textView, let storage = view.textStorage else { return }
            let look = parent.look
            let text = storage.string
            let whole = NSRange(location: 0, length: storage.length)
            let spans = NoteMarkdown.spans(in: text)
            unchecked = NoteMarkdown.unchecked(in: spans)
            let caret = view.selectedRange()
            active = (text as NSString).paragraphRange(for: NSRange(location: min(caret.location, storage.length), length: 0))
            storage.beginEditing()
            let base = NSMutableParagraphStyle()
            base.lineSpacing = 2
            base.paragraphSpacing = 3
            storage.setAttributes([.font: look.body, .foregroundColor: NoteLook.ink, .paragraphStyle: base], range: whole)
            for span in spans {
                let r = span.range
                guard NSMaxRange(r) <= storage.length else { continue }
                switch span.kind {
                case .heading(let level):
                    storage.addAttribute(.font, value: look.heading(level), range: r)
                    let style = NSMutableParagraphStyle()
                    style.paragraphSpacingBefore = level == 1 ? 2 : 6
                    style.paragraphSpacing = 4
                    storage.addAttribute(.paragraphStyle, value: style, range: (text as NSString).paragraphRange(for: r))
                case .bold:
                    let font = storage.attribute(.font, at: r.location, effectiveRange: nil) as? NSFont ?? look.body
                    storage.addAttribute(.font, value: NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask), range: r)
                case .italic:
                    let font = storage.attribute(.font, at: r.location, effectiveRange: nil) as? NSFont ?? look.body
                    storage.addAttribute(.font, value: NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask), range: r)
                case .code:
                    storage.addAttributes([.font: look.code, .noteCode: true], range: r)
                case .codeBlock:
                    storage.addAttributes([.font: look.code, .noteCodeBlock: NSValue(range: r)], range: r)
                    let style = NSMutableParagraphStyle()
                    style.firstLineHeadIndent = 10
                    style.headIndent = 10
                    style.tailIndent = -10
                    style.lineSpacing = 2
                    storage.addAttribute(.paragraphStyle, value: style, range: r)
                case .listItem(let depth):
                    let style = NSMutableParagraphStyle()
                    style.lineSpacing = 2
                    style.paragraphSpacing = 2
                    style.firstLineHeadIndent = 4 + CGFloat(depth) * 18
                    style.headIndent = 4 + CGFloat(depth) * 18 + look.size * 1.05
                    storage.addAttribute(.paragraphStyle, value: style, range: r)
                case .listMarker(let bullet):
                    storage.addAttribute(.foregroundColor, value: NoteLook.quiet, range: r)
                    if bullet { storage.addAttribute(.noteBullet, value: true, range: NSRange(location: r.location, length: 1)) }
                case .quote:
                    storage.addAttribute(.foregroundColor, value: NoteLook.quiet, range: r)
                case .mark:
                    storage.addAttributes([.foregroundColor: NoteLook.marks, .noteMark: false], range: r)
                case .fence:
                    storage.addAttributes([.foregroundColor: NoteLook.marks, .noteMark: false, .font: look.code], range: r)
                }
            }
            // The backticks of code in a line keep their room when hidden (see `conceal`).
            for span in spans where span.kind == .code {
                for mark in spans where mark.kind == .mark && (NSMaxRange(mark.range) == span.range.location || mark.range.location == NSMaxRange(span.range)) {
                    storage.addAttribute(.noteCodeMark, value: true, range: mark.range)
                }
            }
            conceal(storage)
            storage.endEditing()
            view.typingAttributes = [.font: look.body, .foregroundColor: NoteLook.ink, .paragraphStyle: base]
            drawIssues()
        }

        /// Marks outside the paragraph being edited are hidden (a code block's fences: outside the block).
        private func conceal(_ storage: NSTextStorage) {
            let whole = NSRange(location: 0, length: storage.length)
            let focused = textView?.hasKeyboard ?? false
            storage.enumerateAttribute(.noteMark, in: whole) { value, range, _ in
                guard value != nil else { return }
                var showing = focused && NSIntersectionRange(active, range).length > 0
                if let block = storage.attribute(.noteCodeBlock, at: range.location, effectiveRange: nil) as? NSValue {
                    let caret = textView?.selectedRange().location ?? -1
                    showing = focused && caret >= block.rangeValue.location && caret <= NSMaxRange(block.rangeValue)
                }
                if storage.attribute(.noteCodeMark, at: range.location, effectiveRange: nil) != nil {
                    // Drawn clear rather than taken out, so the code's fill does not touch its neighbours.
                    storage.addAttributes([.noteMark: false, .foregroundColor: showing ? NoteLook.marks : NSColor.clear], range: range)
                } else {
                    storage.addAttribute(.noteMark, value: !showing, range: range)
                }
            }
            storage.enumerateAttribute(.noteBullet, in: whole) { value, range, _ in
                guard value != nil else { return }
                storage.addAttribute(.noteBullet, value: !(focused && NSIntersectionRange(active, range).length > 0), range: range)
            }
            for manager in storage.layoutManagers {
                manager.invalidateGlyphs(forCharacterRange: whole, changeInLength: 0, actualCharacterRange: nil)
                manager.invalidateLayout(forCharacterRange: whole, actualCharacterRange: nil)
            }
        }

        /// Hidden marks get no glyph; a bullet's "-" is drawn as "•".
        nonisolated func layoutManager(
            _ layoutManager: NSLayoutManager, shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>, properties props: UnsafePointer<NSLayoutManager.GlyphProperty>,
            characterIndexes charIndexes: UnsafePointer<Int>, font aFont: NSFont, forGlyphRange glyphRange: NSRange
        ) -> Int {
            guard let storage = layoutManager.textStorage else { return 0 }
            let count = glyphRange.length
            var newProps = Array(UnsafeBufferPointer(start: props, count: count))
            var newGlyphs = Array(UnsafeBufferPointer(start: glyphs, count: count))
            var changed = false
            let text = storage.string as NSString
            for i in 0..<count {
                let index = charIndexes[i]
                guard index < storage.length else { continue }
                let ch = text.character(at: index)
                if ch == 0x0A || ch == 0x0D { continue }
                if storage.attribute(.noteMark, at: index, effectiveRange: nil) as? Bool == true {
                    newProps[i].insert(.null)
                    changed = true
                } else if storage.attribute(.noteBullet, at: index, effectiveRange: nil) as? Bool == true {
                    let font = (storage.attribute(.font, at: index, effectiveRange: nil) as? NSFont) ?? aFont
                    var bullet: [UniChar] = [0x2022]
                    var glyph: [CGGlyph] = [0]
                    if CTFontGetGlyphsForCharacters(font as CTFont, &bullet, &glyph, 1), glyph[0] != 0 {
                        newGlyphs[i] = glyph[0]
                        changed = true
                    }
                }
            }
            guard changed else { return 0 }
            layoutManager.setGlyphs(newGlyphs, properties: newProps, characterIndexes: charIndexes, font: aFont, forGlyphRange: glyphRange)
            return count
        }

        // MARK: Editing

        func textDidChange(_ notification: Notification) {
            guard let view = textView else { return }
            let dictated = dictatedPending
            dictatedPending = false
            issues = Proofreading.carry(issues, from: parent.text, to: view.string)
            parent.text = view.string
            restyle()
            parent.onEdit(dictated)
            scheduleCheck(immediately: false)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let view = textView, let storage = view.textStorage else { return }
            let paragraph = (storage.string as NSString).paragraphRange(for: NSRange(location: min(view.selectedRange().location, storage.length), length: 0))
            if paragraph != active {
                active = paragraph
                storage.beginEditing()
                conceal(storage)
                storage.endEditing()
            }
            offerSentenceFix()
            moveChip()
        }

        func textDidBeginEditing(_ notification: Notification) { refreshConcealment() }
        func textDidEndEditing(_ notification: Notification) {
            SentenceFixer.shared.withdraw(owner: "note")
            refreshConcealment()
        }

        /// The marks show only while the note has the keyboard.
        func refreshConcealment() {
            guard let storage = textView?.textStorage else { return }
            storage.beginEditing()
            conceal(storage)
            storage.endEditing()
        }

        // MARK: Writing checks

        private var checking: Bool { parent.checks && Features.on(.write) }

        func scheduleCheck(immediately: Bool) {
            pending?.cancel()
            guard checking, let checker = NoteController.checker else {
                issues = []
                drawIssues()
                return
            }
            pending = Task { [weak self] in
                if !immediately { try? await Task.sleep(for: .milliseconds(250)) }
                guard let self, !Task.isCancelled, let view = self.textView else { return }
                let snapshot = view.string
                let found = await checker.check(snapshot)
                guard !Task.isCancelled, view.string == snapshot else { return }
                // Code, code blocks and marks are not prose: nothing is flagged there.
                let skip = self.unchecked
                self.issues = found.filter { issue in !skip.contains { NSIntersectionRange($0, issue.range).length > 0 } }
                self.drawIssues()
                self.offerSentenceFix()
            }
        }

        private func drawIssues() {
            guard let view = textView, let layout = view.layoutManager else { return }
            // Each kind in its own line: drawn by the layout manager, `PatternLayoutManager`.
            IssueMarks.mark(issues, in: layout, text: view.string)
        }

        func offerSentenceFix() {
            guard let view = textView, view.hasKeyboard, view.selectedRange().length == 0,
                let fix = Proofreading.sentenceFix(in: view.string, caret: view.selectedRange().location, issues: issues)
            else { return SentenceFixer.shared.withdraw(owner: "note") }
            SentenceFixer.shared.offer(fix, owner: "note") { [weak self] in
                guard let view = self?.textView, NSMaxRange(fix.range) <= (view.string as NSString).length else { return }
                if view.shouldChangeText(in: fix.range, replacementString: fix.replacement) {
                    view.replaceCharacters(in: fix.range, with: fix.replacement)
                    view.didChangeText()
                }
            }
        }

        @objc func clicked(_ recognizer: NSClickGestureRecognizer) {
            guard let view = textView, let layout = view.layoutManager, let container = view.textContainer else { return }
            var point = recognizer.location(in: view)
            point.x -= view.textContainerOrigin.x
            point.y -= view.textContainerOrigin.y
            var fraction: CGFloat = 0
            let glyph = layout.glyphIndex(for: point, in: container, fractionOfDistanceThroughGlyph: &fraction)
            let index = layout.characterIndexForGlyph(at: glyph)
            let glyphRect = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
            guard glyphRect.insetBy(dx: -2, dy: -2).contains(point), let issue = issues.first(where: { NSLocationInRange(index, $0.range) }) else { return }
            show(issue)
        }

        /// Opens the suggestion card for an issue (also from a test link).
        func show(_ issue: WritingIssue) {
            guard let view = textView, let layout = view.layoutManager, let container = view.textContainer else { return }
            popover?.close()
            let glyphs = layout.glyphRange(forCharacterRange: issue.range, actualCharacterRange: nil)
            var rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
            rect.origin.x += view.textContainerOrigin.x
            rect.origin.y += view.textContainerOrigin.y
            let pop = NSPopover()
            pop.behavior = .transient
            pop.contentViewController = NSHostingController(
                rootView: IssueCard(issue: issue, text: view.string) { [weak self] action in
                    self?.popover?.close()
                    self?.perform(action, on: issue)
                })
            pop.show(relativeTo: rect, of: view, preferredEdge: .maxY)
            popover = pop
        }

        func perform(_ action: IssueAction, on issue: WritingIssue) {
            guard let view = textView, let engine = NoteController.engine else { return }
            let text = view.string
            switch action {
            case .apply(let fix):
                guard issues.contains(issue) else { break }
                CorrectionTally.note(issue, fix: fix, wrong: issue.flagged(in: text), engine: engine)
                let new = Proofreading.apply(fix, to: issue, in: text).text
                let old = text as NSString
                let nw = new as NSString
                var prefix = 0
                while prefix < min(old.length, nw.length), old.character(at: prefix) == nw.character(at: prefix) { prefix += 1 }
                var suffix = 0
                while suffix < min(old.length, nw.length) - prefix, old.character(at: old.length - 1 - suffix) == nw.character(at: nw.length - 1 - suffix) { suffix += 1 }
                if prefix > 0, UTF16.isLeadSurrogate(old.character(at: prefix - 1)) { prefix -= 1 }
                if suffix > 0, UTF16.isTrailSurrogate(old.character(at: old.length - suffix)) { suffix -= 1 }
                let range = NSRange(location: prefix, length: old.length - prefix - suffix)
                let replacement = nw.substring(with: NSRange(location: prefix, length: nw.length - prefix - suffix))
                if range.length > 0 || !replacement.isEmpty, view.shouldChangeText(in: range, replacementString: replacement) {
                    view.replaceCharacters(in: range, with: replacement)
                    view.didChangeText()
                }
            case .dismiss: try? engine.dismiss(ruleKey: issue.rule, text: issue.flagged(in: text))
            case .dismissRule: try? engine.dismiss(ruleKey: issue.rule, text: nil)
            case .addToDictionary: _ = try? engine.addWord(issue.flagged(in: text))
            case .rewrite, .acceptRewrite, .close: break
            }
            scheduleCheck(immediately: true)
        }

        // MARK: Listening

        /// While right ⌥ is held over the note, a small mark at the cursor says the words will go there.
        func showListening(_ on: Bool, level: Double) {
            guard let view = textView else { return }
            if on {
                if chip == nil {
                    let host = NSHostingView(rootView: ListeningChip(level: level))
                    host.setAccessibilityLabel("Listening")
                    view.addSubview(host)
                    chip = host
                }
                chip?.rootView = ListeningChip(level: level)
                moveChip()
            } else if let chip {
                chip.removeFromSuperview()
                self.chip = nil
            }
        }

        private func moveChip() {
            guard let chip, let view = textView, let layout = view.layoutManager, let container = view.textContainer else { return }
            let at = min(view.selectedRange().location, (view.string as NSString).length)
            var caret: NSRect
            if at > 0 {
                let glyph = layout.glyphIndexForCharacter(at: at - 1)
                caret = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
                caret.origin.x = caret.maxX
            } else {
                caret = NSRect(x: 0, y: 0, width: 0, height: parent.look.size + 4)
            }
            let size = chip.fittingSize
            var x = caret.minX + view.textContainerOrigin.x + 6
            if x + size.width > view.bounds.width - 4 { x = max(4, view.bounds.width - size.width - 4) }
            chip.frame = NSRect(x: x, y: caret.midY + view.textContainerOrigin.y - size.height / 2, width: size.width, height: size.height)
        }
    }
}

/// The small "listening" mark at a note's cursor while right ⌥ is held.
struct ListeningChip: View {
    var level: Double

    var body: some View {
        HStack(spacing: 5) {
            HStack(spacing: 2) {
                ForEach(0..<5, id: \.self) { i in
                    let shape = [0.4, 0.85, 0.6, 1.0, 0.45][i]
                    Capsule().fill(Color.onAmber)
                        .frame(width: 2, height: max(3, 13 * shape * max(0.25, min(1, level * 3))))
                }
            }
            Text("hold ⌥").font(.system(size: 11, weight: .medium)).foregroundStyle(Color.onAmber)
        }
        .padding(.horizontal, 7).frame(height: 20)
        .background(Color.amber.opacity(0.85), in: Capsule())
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Listening")
    }
}
