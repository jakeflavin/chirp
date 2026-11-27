import AppKit
import ChirpCore
import KeyboardShortcuts
import Observation
import SwiftUI

extension KeyboardShortcuts.Name {
    /// Opens the panel on the text selected in any app.
    /// Right Option and I, for Improve (see `ShortcutLayout`).
    static let writePanel = Self("writePanel", initial: .init(.i, modifiers: [.option]))
    /// Right ⌥ K: the rephrase card on the selected text. Right ⌥ I is Fix writing.
    static let rephrase = Self("rephrase", initial: .init(.k, modifiers: [.option]))
}

/// The panel that opens on a shortcut with the text selected in any app: proofread, shorten, write out
/// or rephrase it, see what would change, and replace it in place. It also asks for the cue when words
/// are saved as a snippet.
@MainActor
@Observable
final class SelectionPanelController {
    /// The panel is as tall as its words need: a sentence gets a small panel, a page gets the full one.
    /// Room is left for the crossed-out and added words a fix shows side by side.
    static func height(for text: String) -> CGFloat {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .reduce(0) { $0 + max(1, Int((Double($1.count) * 1.4 / 58).rounded(.up))) }
        let box = min(max(CGFloat(lines) * 19 + 24, 64), 190)
        return 170 + box
    }
    /// The words the panel is working on, without the space around them.
    private(set) var text = ""
    /// What the instant check found in them.
    private(set) var issues: [WritingIssue] = []
    /// Shown when there was nothing to work on, or the result could only be copied.
    private(set) var notice: String?
    /// The app the words came from, so a rewrite can suit it.
    private(set) var context = WorkContext()
    /// Set when nothing was selected and the panel is working on the whole text field instead.
    private var wholeField: AXUIElement?
    /// True when the panel has the whole text field, not a selection.
    var isWholeField: Bool { wholeField != nil }

    /// The words being saved as a snippet, while the panel asks for their cue. Nil otherwise.
    private(set) var snippetText: String?
    /// The cue being typed for them.
    var cue = ""
    /// Why the snippet could not be saved, in a few words.
    private(set) var snippetProblem: String?
    /// True when the cue is being asked for straight from the More menu, with no rewrite panel behind it.
    private var snippetOnly = false
    /// Says a line on the perch ("Saved to Snippets").
    var onSaved: ((String) -> Void)?
    private let engine: PersonalLanguage

    /// Runs the rewrites and holds their result.
    let assistant: WritingAssistant
    /// The spaces and line breaks around the selection (a paragraph picked with three clicks ends with its
    /// line break). They are not part of the words worked on, and go back around whatever replaces them.
    private var lead = ""
    private var trail = ""
    /// Whether the panel is showing. It is drawn as part of Chirp's bar (the perch), which grows to hold
    /// it, not as a window of its own.
    private(set) var shown = false {
        didSet { if shown != oldValue { onShown?(shown) } }
    }
    /// Tells the perch to make room, take the keyboard for Escape, or give it back.
    var onShown: ((Bool) -> Void)?
    /// Asks the perch to hand the keyboard back to the app in front before text is put in.
    var releaseKeyboard: (() -> Void)?

    init(app: AppModel, assistant: WritingAssistant) {
        self.assistant = assistant
        engine = app.engine
        KeyboardShortcuts.onKeyUp(for: .rephrase) { [weak self] in
            Task { await self?.openForSelection() }
        }
        LinkHandler.commands["panel"] = { [weak self] q in self?.open(with: q["text"] ?? "") }
        LinkHandler.commands["panel-run"] = { [weak self] q in
            guard let self, let task = WriteModel.task(named: q["task"] ?? "") else { return }
            self.run(task)
        }
        LinkHandler.commands["panel-close"] = { [weak self] _ in self?.close() }
        LinkHandler.commands["panel-again"] = { [weak self] _ in self?.tryAgain() }
        // `panel-snippet` asks for a cue for the panel's words (`text=…` opens it on those words alone, as
        // More does); `cue=…&save=1` types the cue and saves; `cancel=1` puts the question away.
        LinkHandler.commands["panel-snippet"] = { [weak self] q in
            guard let self else { return }
            if let text = q["text"] { self.askCue(for: text, alone: true) } else if self.snippetText == nil, q["cancel"] != "1" { self.saveAsSnippet() }
            if let cue = q["cue"] { self.cue = cue }
            if q["save"] == "1" { self.saveSnippet() }
            if q["cancel"] == "1" { self.cancelSnippet() }
        }
        LinkHandler.stateProviders["panel"] = { [weak self] in
            guard let self else { return [:] }
            return [
                "open": self.shown, "text": self.text, "issues": self.issues.count,
                "result": self.assistant.result, "busy": self.assistant.busy != nil, "notice": self.notice ?? "",
                "tone": self.assistant.tone, "wholeField": self.isWholeField,
                "task": self.assistant.task?.title ?? "", "refused": self.assistant.refused ?? "",
                "problems": self.assistant.lastProblems.map(\.rawValue),
                "snippet": self.snippetText ?? "", "cue": self.cue, "snippetProblem": self.snippetProblem ?? "",
            ]
        }
    }

    /// Reads the selection of the frontmost app and opens the panel on it.
    func openForSelection() async {
        guard Features.on(.write) else { return }
        let front = NSWorkspace.shared.frontmostApplication
        context = WorkContext(bundleID: front?.bundleIdentifier, appName: front?.localizedName)
        guard AXIsProcessTrusted() else {
            open(with: "")
            notice = "Allow Accessibility for Chirp in System Settings so it can read the text you select."
            return
        }
        var selected = TextInserter.selectedText()
        if selected == nil { selected = await TextInserter.copySelection() }
        var field: AXUIElement?
        if selected == nil, let element = TextInserter.focusedElement(), UnderlineController.isEditableText(element),
            let value = TextInserter.text(of: element), value.utf16.count < 20_000,
            !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            // Nothing selected: work on everything in the text field.
            selected = value
            field = element
        }
        Log.write("write", "panel: \(selected?.count ?? 0) characters, \(field != nil ? "whole field" : "selection") in \(front?.bundleIdentifier ?? "?")")
        open(with: selected ?? "")
        wholeField = field
    }

    /// Shows the panel for `text` and checks it.
    func open(with text: String) {
        guard Features.on(.write) else { return }
        assistant.clear()
        wholeField = nil
        snippetText = nil
        snippetOnly = false
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.text = trimmed
        lead = ""
        trail = ""
        if !trimmed.isEmpty, let middle = text.range(of: trimmed) {
            lead = String(text[..<middle.lowerBound])
            trail = String(text[middle.upperBound...])
        }
        notice = self.text.isEmpty ? "Click into a text field or select some text first, then press the shortcut." : nil
        issues = self.text.isEmpty ? [] : assistant.checker.checkNow(self.text)
        if GrammarChecker.deepEnabled, !self.text.isEmpty {
            let snapshot = self.text
            Task { [weak self] in
                guard let self else { return }
                if await self.assistant.checker.deepen(snapshot), self.text == snapshot {
                    let found = await self.assistant.checker.check(snapshot)
                    if self.text == snapshot { self.issues = found }
                }
                await self.assistant.detectTone(snapshot)
            }
        }

        shown = true
    }

    /// Puts the panel away and drops any result.
    func close() {
        assistant.clear()
        snippetText = nil
        snippetOnly = false
        shown = false
    }

    /// Runs the showing rewrite once more.
    func tryAgain() {
        guard let task = assistant.task else { return }
        run(task)
    }

    // MARK: Save as a snippet

    /// Asks for a cue for the result on show, or for the panel's own words when there is none.
    func saveAsSnippet() {
        askCue(for: assistant.result.isEmpty || assistant.busy != nil ? text : assistant.result, alone: false)
    }

    /// Reads the selection of the app in front and asks for a cue for it: More › Save as a Snippet….
    func saveSelectionAsSnippet() async {
        var selected = TextInserter.selectedText()
        if selected == nil { selected = await TextInserter.copySelection() }
        guard let selected, !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            onSaved?("Select some text first.")
            return
        }
        askCue(for: selected, alone: true)
    }

    /// Shows the cue question for `words`. `alone` is true when there is no rewrite panel to go back to.
    func askCue(for words: String, alone: Bool) {
        let trimmed = words.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if alone {
            assistant.clear()
            text = ""
            notice = nil
            issues = []
        }
        snippetOnly = alone
        snippetText = trimmed
        cue = ""
        snippetProblem = nil
        shown = true
    }

    /// Cancel on the cue question: back to the rewrite it came from, or away.
    func cancelSnippet() {
        if snippetOnly { return close() }
        snippetText = nil
        snippetProblem = nil
    }

    /// Saves the words under the cue typed. Nothing is saved without a cue, or over another snippet's cue.
    func saveSnippet() {
        guard let words = snippetText else { return }
        let name = cue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            snippetProblem = "Give it a cue first."
            return
        }
        let existing = (try? engine.snippets(includeDisabled: true)) ?? []
        guard !existing.contains(where: { $0.cue.caseInsensitiveCompare(name) == .orderedSame }) else {
            snippetProblem = "You already have a snippet with that cue."
            return
        }
        do {
            try engine.save(Snippet(cue: name, text: words))
            Log.write("write", "snippet saved from \(snippetOnly ? "a selection" : "the rewrite panel") (\(words.count) characters)")
            let back = !snippetOnly
            snippetText = nil
            snippetProblem = nil
            if back { onSaved?("Saved to Snippets") } else {
                close()
                onSaved?("Saved to Snippets")
            }
        } catch {
            snippetProblem = "Could not save it."
        }
    }

    /// Starts a rewrite of the panel's text.
    func run(_ task: WritingTask) {
        guard !text.isEmpty else { return }
        assistant.run(task, on: text, context: context)
    }

    /// Spelling and grammar fixes only, instantly, without the language model.
    var quickFixed: String { Proofreading.fixAll(issues, in: text) }

    /// The problems that fix would change: spelling and grammar with a suggestion, leaving likely names alone
    /// (the same choice `Proofreading.fixAll` makes). Style suggestions are found too, but not counted or applied here.
    var fixable: [WritingIssue] {
        issues.filter { $0.category != .style && !$0.suggestions.isEmpty && !Proofreading.likelyName($0, in: text) }
    }

    /// Puts `replacement` where the selection was, with the space that was around the selection kept.
    func replace(with replacement: String) {
        let padded = lead + replacement + trail
        Task {
            // The perch never made Chirp the active app, so the original app still has its selection.
            // It does hold the keyboard (for Escape), which goes back first so the text lands in that app.
            shown = false
            releaseKeyboard?()
            try? await Task.sleep(for: .milliseconds(120))
            if let wholeField, !TextInserter.selectAll(in: wholeField) {
                // The app would not let Chirp select its text, so typing would land at the cursor instead.
                TextInserter.copy(replacement)
                notice = "Copied. Select all in the text field (⌘A) and paste."
                shown = true
                return
            }
            let outcome = await TextInserter.insert(padded)
            if outcome == .copiedOnly {
                notice = "Copied. Press ⌘V to paste it over your selection."
                shown = true
            } else {
                assistant.clear()
            }
        }
    }
}

/// The panel itself, as part of the perch's surface: the rewrites Chirp can do, the text or what would
/// change in it, and a foot row with the button that puts the result back.
struct SelectionPanelView: View {
    let controller: SelectionPanelController
    let perch: PerchController

    var body: some View {
        if controller.snippetText != nil {
            SnippetCueView(controller: controller, perch: perch)
        } else {
            rewrite
        }
    }

    private var rewrite: some View {
        let assistant = controller.assistant
        return PerchSection(
            perch: perch, kind: .rephrase, title: "Rewrite", meta: detail, resizable: !controller.text.isEmpty,
            close: { controller.close() }
        ) {
            VStack(alignment: .leading, spacing: 10) {
                if let notice = controller.notice {
                    Text(notice).font(.system(size: 12.5)).foregroundStyle(GlassFill.quiet).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("panel.notice")
                }
                if !controller.text.isEmpty {
                    // What Chirp can do with these words. Each keeps them yours: it rewords, it does not write for you.
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 6) { chips(0..<6) }
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 6) { chips(0..<3) }
                            HStack(spacing: 6) { chips(3..<6) }
                        }
                    }
                    .accessibilityElement(children: .contain).accessibilityLabel("Rewrite")

                    PerchScroll(limit: max(64, perch.bodyHeight(for: .rephrase) - 70)) {
                        Group {
                            if assistant.task == nil {
                                // Before any action: show the instant spelling and grammar fixes, if there are any.
                                if controller.fixable.isEmpty {
                                    Text(controller.text)
                                } else {
                                    DiffText(old: controller.text, new: controller.quickFixed)
                                }
                            } else if let refused = assistant.refused {
                                // The rewrite failed the check that it is still the author's text: it is not offered.
                                Text(refused).foregroundStyle(GlassFill.quiet).accessibilityIdentifier("panel.refused")
                            } else if assistant.task == .writeOut {
                                writtenOut
                            } else if assistant.result.isEmpty {
                                Text("Working on it…").foregroundStyle(GlassFill.quiet)
                            } else if assistant.busy != nil {
                                Text(assistant.result)
                            } else {
                                DiffText(old: assistant.source, new: assistant.result)
                            }
                        }
                        .font(.system(size: 13.5)).lineSpacing(2)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 2).padding(.vertical, 2)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18).padding(.top, 10).padding(.bottom, 4)
        } foot: {
            // The perch has the keyboard while this is open, so Return does the main thing.
            if controller.text.isEmpty {
                EmptyView()
            } else if assistant.task == nil {
                if controller.fixable.isEmpty {
                    Text("No spelling or grammar issues").font(.system(size: 12.5)).foregroundStyle(GlassFill.quiet).padding(.leading, 6)
                } else {
                    PerchAct(perch: perch, title: "Fix \(controller.fixable.count) and replace", primary: true, key: "↵") {
                        controller.replace(with: controller.quickFixed)
                    }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("panel.fix")
                }
                PerchAct(perch: perch, title: "Save as a snippet") { controller.saveAsSnippet() }
            } else {
                let waiting = assistant.busy != nil || assistant.result.isEmpty
                PerchAct(perch: perch, title: "Replace", primary: true, key: "↵") { controller.replace(with: assistant.result) }
                    .disabled(waiting).opacity(waiting ? 0.5 : 1)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("panel.replace")
                PerchAct(perch: perch, title: "Copy") { TextInserter.copy(assistant.result) }
                    .disabled(waiting).opacity(waiting ? 0.5 : 1)
                PerchAct(perch: perch, title: "Try again") { controller.tryAgain() }
                    .disabled(assistant.busy != nil).opacity(assistant.busy != nil ? 0.5 : 1)
                PerchAct(perch: perch, title: "Save as a snippet") { controller.saveAsSnippet() }
                    .disabled(waiting).opacity(waiting ? 0.5 : 1)
            }
        }
    }

    /// "Write out": the author's points as they wrote them, then the same points as sentences.
    @ViewBuilder private var writtenOut: some View {
        let assistant = controller.assistant
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Yours").font(.system(size: 11, weight: .semibold)).foregroundStyle(GlassFill.quiet.opacity(0.8))
                ForEach(Array(points.enumerated()), id: \.offset) { _, point in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Circle().fill(GlassFill.quiet.opacity(0.7)).frame(width: 4, height: 4).offset(y: -3)
                        Text(point).font(.system(size: 12.5)).foregroundStyle(GlassFill.quiet).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("Written out").font(.system(size: 11, weight: .semibold)).foregroundStyle(GlassFill.quiet.opacity(0.8))
                Text(assistant.result.isEmpty ? "Working on it…" : assistant.result)
                    .foregroundStyle(assistant.result.isEmpty ? GlassFill.quiet : GlassFill.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The author's text as its separate points, without the marks that began each line.
    private var points: [String] {
        controller.assistant.source.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \t-•*–—")) }.filter { !$0.isEmpty }
    }

    /// The grey words after the heading: how the text sounds, how much was selected, and where.
    private var detail: String {
        var parts: [String] = []
        if !controller.assistant.tone.isEmpty, controller.assistant.toneFor == controller.text { parts.append("sounds \(controller.assistant.tone)") }
        let lines = controller.text.split(whereSeparator: \.isNewline).count
        let name = controller.context.appName
        if controller.isWholeField {
            parts.append(name.map { "in \($0), whole field" } ?? "whole field")
        } else if lines > 1 {
            parts.append("\(lines) lines selected" + (name.map { " in \($0)" } ?? ""))
        } else if let name {
            parts.append("in \(name)")
        }
        return parts.joined(separator: " · ")
    }

    /// The rewrites, in the order the panel shows them.
    private static let tasks: [(String, WritingTask)] = [
        ("Proofread", .fix), ("Shorten", .shorten), ("Write out", .writeOut), ("Rephrase", .rephrase(.neutral)),
        ("More casual", .rephrase(.casual)), ("More formal", .rephrase(.formal)),
    ]

    @ViewBuilder private func chips(_ range: Range<Int>) -> some View {
        ForEach(Array(Self.tasks[range].enumerated()), id: \.offset) { _, entry in chip(entry.0, entry.1) }
    }

    /// One thing Chirp can do with the text, tinted while it is the one showing.
    private func chip(_ label: String, _ task: WritingTask) -> some View {
        let current = controller.assistant.task == task
        return Button { controller.run(task) } label: {
            Text(label).font(.system(size: 12.5, weight: current ? .semibold : .regular)).lineLimit(1).fixedSize()
                .foregroundStyle(current ? PerchStyle.onAmber : GlassFill.ink)
                .padding(.horizontal, 10).frame(height: PerchStyle.act)
                .background(current ? PerchStyle.amber : GlassFill.row, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(PerchPress())
        .disabled(controller.assistant.busy != nil)
        .accessibilityLabel(label)
        .accessibilityAddTraits(current ? .isSelected : [])
    }
}

/// "Save as a snippet": the words, and the one thing asked for, their cue.
struct SnippetCueView: View {
    let controller: SelectionPanelController
    let perch: PerchController
    @FocusState private var typing: Bool

    var body: some View {
        @Bindable var controller = controller
        PerchSection(perch: perch, kind: .rephrase, title: "Save as a snippet", resizable: false, close: { controller.cancelSnippet() }) {
            VStack(alignment: .leading, spacing: 10) {
                Text(controller.snippetText ?? "").font(.system(size: 12.5)).lineSpacing(2).foregroundStyle(GlassFill.quiet)
                    .lineLimit(6).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 11).padding(.vertical, 8)
                    .background(GlassFill.row, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                HStack(spacing: 10) {
                    Text("Cue").font(.system(size: 13, weight: .medium))
                    TextField("", text: $controller.cue)
                        .textFieldStyle(.plain).font(.system(size: 13))
                        .padding(.horizontal, 9).frame(height: 30)
                        .background(GlassFill.row, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(PerchStyle.amber.opacity(typing ? 0.7 : 0), lineWidth: 2))
                        .focused($typing)
                        .onSubmit { controller.saveSnippet() }
                        .accessibilityLabel("Cue")
                        .accessibilityIdentifier("snippet.cue")
                }
                Text(controller.snippetProblem ?? "Say the cue while dictating, or type it and accept the suggestion.")
                    .font(.system(size: 12)).foregroundStyle(controller.snippetProblem == nil ? GlassFill.quiet.opacity(0.85) : Color.caution)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 18).padding(.top, 10).padding(.bottom, 4)
            .onAppear { typing = true }
        } foot: {
            PerchAct(perch: perch, title: "Save", primary: true, key: "↵") { controller.saveSnippet() }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("snippet.save")
            PerchAct(perch: perch, title: "Cancel") { controller.cancelSnippet() }
        }
    }
}
