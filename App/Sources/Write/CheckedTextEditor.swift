import AppKit
import ChirpCore
import SwiftUI

extension IssueCategory {
    /// The underline colour for this kind of problem.
    var color: NSColor {
        switch self {
        case .spelling: NSColor(named: "Spelling") ?? .systemRed
        case .grammar: NSColor(named: "Grammar") ?? .systemBlue
        case .style: NSColor(named: "Style") ?? .systemGreen
        // A snippet is the bird offering something, not a mistake: the amber that reads on a page.
        case .snippet: NSColor(named: "Caution") ?? .systemOrange
        }
    }

    /// The name shown for this kind of problem.
    var title: String {
        switch self {
        case .spelling: "Spelling"
        case .grammar: "Grammar"
        case .style: "Style"
        case .snippet: "Snippet"
        }
    }
}

/// What the user chose to do about an issue.
enum IssueAction {
    case apply(Fix)
    /// Hide this suggestion for this exact text.
    case dismiss
    /// Never show this kind of suggestion again.
    case dismissRule
    /// Add the flagged word to the personal dictionary.
    case addToDictionary
    /// Rewrite the note's sentence with the language model and show the change.
    case rewrite
    /// Put the rewritten sentence in.
    case acceptRewrite
    /// Put the card away and change nothing.
    case close
}

/// A text editor that underlines spelling, grammar and style issues as you type.
/// Clicking an underline opens a card with the fix.
struct CheckedTextEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var issues: [WritingIssue]
    let checker: GrammarChecker
    let engine: PersonalLanguage
    /// Bumped by the parent to force a re-check (after the dictionary changes, say).
    var recheck: Int = 0

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        // TextKit 1 with Chirp's layout manager, which draws each kind of underline in its own line.
        let storage = NSTextStorage()
        let layout = PatternLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        let view = NSTextView(frame: .zero, textContainer: container)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.minSize = NSSize(width: 0, height: 0)
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        let scroll = NSScrollView()
        scroll.documentView = view
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        view.delegate = context.coordinator
        view.font = .systemFont(ofSize: 15)
        view.textContainerInset = NSSize(width: 14, height: 14)
        view.isRichText = false
        view.allowsUndo = true
        view.drawsBackground = false
        scroll.drawsBackground = false
        // Chirp does the checking; the system's red dots would double up.
        view.isContinuousSpellCheckingEnabled = false
        view.isGrammarCheckingEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        // Chirp never offers Apple's Writing Tools: its own models do that work.
        view.writingToolsBehavior = .none
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.setAccessibilityIdentifier("write.editor")
        view.string = text
        context.coordinator.textView = view
        let click = NSClickGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.clicked(_:)))
        click.delaysPrimaryMouseButtonEvents = false
        view.addGestureRecognizer(click)
        context.coordinator.scheduleCheck(immediately: true)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        context.coordinator.parent = self
        if view.string != text {
            view.string = text
            // The steps that could be undone were recorded against the old text and no longer fit this one.
            view.undoManager?.removeAllActions()
            context.coordinator.scheduleCheck(immediately: true)
        }
        if context.coordinator.lastRecheck != recheck {
            context.coordinator.lastRecheck = recheck
            context.coordinator.scheduleCheck(immediately: true)
        }
    }

    /// Sits between the text view and SwiftUI: passes edits up, runs the checks, draws the underlines and
    /// opens the card for a clicked one.
    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        /// The SwiftUI side, replaced on every update so its bindings stay current.
        var parent: CheckedTextEditor
        weak var textView: NSTextView?
        /// The value of `recheck` last acted on.
        var lastRecheck = 0
        /// The editor on screen, for test hooks.
        static weak var current: Coordinator?
        /// The check waiting for typing to pause, or running. A newer one cancels it.
        private var pending: Task<Void, Never>?
        /// The open suggestion card, if any.
        private var popover: NSPopover?

        init(_ parent: CheckedTextEditor) {
            self.parent = parent
            super.init()
            Self.current = self
        }

        func textViewDidChangeSelection(_ notification: Notification) { offerSentenceFix() }
        func textDidEndEditing(_ notification: Notification) { SentenceFixer.shared.withdraw(owner: "editor") }

        /// If the sentence at the cursor has fixes, show the shortcut that applies them all.
        func offerSentenceFix() {
            guard let textView, textView.window?.firstResponder === textView, textView.selectedRange().length == 0,
                let fix = Proofreading.sentenceFix(in: textView.string, caret: textView.selectedRange().location, issues: parent.issues)
            else { return SentenceFixer.shared.withdraw(owner: "editor") }
            SentenceFixer.shared.offer(fix, owner: "editor") { [weak self] in
                guard let self, let textView = self.textView, NSMaxRange(fix.range) <= (textView.string as NSString).length else { return }
                // Through the text view, so undo puts the sentence back.
                if textView.shouldChangeText(in: fix.range, replacementString: fix.replacement) {
                    textView.replaceCharacters(in: fix.range, with: fix.replacement)
                    textView.didChangeText()
                }
            }
        }

        /// Moves the cursor (test hook).
        func setCaret(_ location: Int) {
            guard let textView else { return }
            textView.window?.makeFirstResponder(textView)
            textView.setSelectedRange(NSRange(location: min(location, (textView.string as NSString).length), length: 0))
            offerSentenceFix()
        }

        /// The user typed: pass the text up and check again once typing pauses.
        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            // Until the next check, what was found keeps its place: problems after the edit move along with
            // their words, and any the edit touched are dropped. Left as they were, they would point at the
            // wrong letters, and a fix applied in that moment would land there.
            let carried = Proofreading.carry(parent.issues, from: parent.text, to: textView.string)
            parent.issues = carried
            parent.text = textView.string
            draw(carried)
            offerSentenceFix()
            scheduleCheck(immediately: false)
        }

        /// Checks the text, after a short pause unless `immediately`, then stores and draws what was found.
        /// A result for text that has since changed is thrown away.
        func scheduleCheck(immediately: Bool) {
            pending?.cancel()
            pending = Task { [weak self] in
                if !immediately { try? await Task.sleep(for: .milliseconds(250)) }
                guard let self, !Task.isCancelled, let textView = self.textView else { return }
                let snapshot = textView.string
                let found = await self.parent.checker.check(snapshot)
                // The text may have changed while checking; if so a newer check is already queued.
                guard !Task.isCancelled, textView.string == snapshot else { return }
                self.parent.issues = found
                self.draw(found)
                self.offerSentenceFix()
            }
        }

        /// Underlines each problem in its colour. The underlines are for show only and are not part of the text.
        private func draw(_ issues: [WritingIssue]) {
            guard let textView, let layout = textView.layoutManager else { return }
            // Each kind in its own line: drawn by the layout manager, `PatternLayoutManager`.
            IssueMarks.mark(issues, in: layout, text: textView.string)
        }

        /// A click on underlined text opens its card.
        @objc func clicked(_ recognizer: NSClickGestureRecognizer) {
            guard let textView, let layout = textView.layoutManager, let container = textView.textContainer else { return }
            var point = recognizer.location(in: textView)
            point.x -= textView.textContainerOrigin.x
            point.y -= textView.textContainerOrigin.y
            var fraction: CGFloat = 0
            let glyph = layout.glyphIndex(for: point, in: container, fractionOfDistanceThroughGlyph: &fraction)
            let index = layout.characterIndexForGlyph(at: glyph)
            // Only count clicks that land on the text itself, not the empty space after a line.
            let glyphRect = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
            guard glyphRect.insetBy(dx: -2, dy: -2).contains(point),
                let issue = parent.issues.first(where: { NSLocationInRange(index, $0.range) })
            else { return }
            show(issue)
        }

        /// Opens the suggestion card for an issue. Also used by tests through a debug link.
        func show(_ issue: WritingIssue) {
            guard let textView, let layout = textView.layoutManager, let container = textView.textContainer else { return }
            popover?.close()
            let glyphs = layout.glyphRange(forCharacterRange: issue.range, actualCharacterRange: nil)
            var rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
            rect.origin.x += textView.textContainerOrigin.x
            rect.origin.y += textView.textContainerOrigin.y
            let pop = NSPopover()
            pop.behavior = .transient
            pop.contentViewController = NSHostingController(
                rootView: IssueCard(issue: issue, text: textView.string) { [weak self] action in
                    self?.popover?.close()
                    self?.perform(action, on: issue)
                })
            pop.show(relativeTo: rect, of: textView, preferredEdge: .maxY)
            popover = pop
        }

        /// Carries out what was chosen on the card, then checks again.
        func perform(_ action: IssueAction, on issue: WritingIssue) {
            guard let textView else { return }
            let text = textView.string
            switch action {
            case .apply(let fix):
                // A card opened before the text last changed points at the wrong place: check again instead.
                guard parent.issues.contains(issue) else { break }
                CorrectionTally.note(issue, fix: fix, wrong: issue.flagged(in: text), engine: parent.engine)
                let old = text as NSString
                let new = Proofreading.apply(fix, to: issue, in: text).text as NSString
                // Only the part that differs is replaced, so the cursor and the page stay where they are.
                var prefix = 0
                while prefix < min(old.length, new.length), old.character(at: prefix) == new.character(at: prefix) { prefix += 1 }
                var suffix = 0
                while suffix < min(old.length, new.length) - prefix,
                    old.character(at: old.length - 1 - suffix) == new.character(at: new.length - 1 - suffix)
                { suffix += 1 }
                // Never start or end in the middle of an emoji (two units that only mean something together).
                if prefix > 0, UTF16.isLeadSurrogate(old.character(at: prefix - 1)) { prefix -= 1 }
                if suffix > 0, UTF16.isTrailSurrogate(old.character(at: old.length - suffix)) { suffix -= 1 }
                let range = NSRange(location: prefix, length: old.length - prefix - suffix)
                let replacement = new.substring(with: NSRange(location: prefix, length: new.length - prefix - suffix))
                // Replace through the text view so undo works.
                if range.length > 0 || !replacement.isEmpty, textView.shouldChangeText(in: range, replacementString: replacement) {
                    textView.replaceCharacters(in: range, with: replacement)
                    textView.didChangeText()
                }
            case .dismiss:
                try? parent.engine.dismiss(ruleKey: issue.rule, text: issue.flagged(in: text))
            case .dismissRule:
                try? parent.engine.dismiss(ruleKey: issue.rule, text: nil)
            case .addToDictionary:
                _ = try? parent.engine.addWord(issue.flagged(in: text))
            case .rewrite, .acceptRewrite, .close:
                // A note's rewrite is offered on the card over other apps; this editor is only for tests.
                break
            }
            scheduleCheck(immediately: true)
        }
    }
}

/// The card shown for one issue: what is wrong, the fixes, and ways to dismiss it.
struct IssueCard: View {
    let issue: WritingIssue
    let text: String
    let act: (IssueAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Circle().fill(Color(nsColor: issue.category.color)).frame(width: 8, height: 8)
                Text(issue.category.title).font(.caption.weight(.semibold)).foregroundStyle(Color.quiet)
            }
            Text(issue.message).font(.callout).fixedSize(horizontal: false, vertical: true)
            if !issue.suggestions.isEmpty {
                FlowButtons(
                    labels: issue.suggestions.prefix(4).map { issue.label(for: $0, in: text) },
                    action: { i in act(.apply(issue.suggestions[i])) })
            }
            Divider()
            HStack(spacing: 12) {
                Button("Dismiss") { act(.dismiss) }
                if issue.category == .spelling {
                    Button("Add to dictionary") { act(.addToDictionary) }
                } else {
                    Button("Don't check this") { act(.dismissRule) }
                        .help("Stop showing this kind of suggestion. You can bring it back in the Library, under Writing style › Learned.")
                }
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
        .padding(14)
        .frame(width: 300, alignment: .leading)
    }
}

/// Suggestion buttons, stacked so long replacements stay readable.
struct FlowButtons: View {
    let labels: [String]
    let action: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(labels.enumerated()), id: \.offset) { index, label in
                Button {
                    action(index)
                } label: {
                    Text(label).frame(maxWidth: .infinity, alignment: .leading).lineLimit(2)
                }
                .buttonStyle(.borderedProminent)
                .tint(index == 0 ? Color.accentColor : Color.quiet)
            }
        }
    }
}

/// Shows what changed between two versions: removed words struck through, added words highlighted.
struct DiffText: View {
    let old: String
    let new: String

    var body: some View {
        Text(attributed).font(.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Above this many words on either side the text is shown plain: comparing two long texts word by word
    /// takes memory that grows with one length times the other.
    private static let wordLimit = 600

    private var attributed: AttributedString {
        guard TextStats.words(old) <= Self.wordLimit, TextStats.words(new) <= Self.wordLimit else { return AttributedString(new) }
        var out = AttributedString()
        // Each word is followed by what follows it in the new text, so the comparison keeps the new text's
        // lines and paragraphs (an email stays laid out like an email). Words taken out sit on the line
        // they were taken from.
        let breaks = WordDiff.breaks(after: new)
        var word = 0
        for op in WordDiff.diff(from: old, to: new) {
            switch op {
            case .same(let w):
                out += AttributedString(w + (word < breaks.count ? breaks[word] : " "))
                word += 1
            case .removed(let w):
                var a = AttributedString(w)
                a.strikethroughStyle = .single
                a.foregroundColor = Color.spelling
                out += a + AttributedString(" ")
            case .added(let w):
                var a = AttributedString(w)
                a.foregroundColor = Color.style
                a.underlineStyle = .single
                out += a + AttributedString(word < breaks.count ? breaks[word] : " ")
                word += 1
            }
        }
        return out
    }
}
