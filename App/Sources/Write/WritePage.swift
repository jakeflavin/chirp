import ChirpCore
import Observation
import SwiftUI

/// The draft in Chirp's own editor.
@MainActor
@Observable
final class WriteModel {
    /// The one draft editor, so a document dropped on the perch can be handed to it.
    static weak var shared: WriteModel?
    /// The draft. Every change is saved shortly after, and looked at by the deeper check once typing pauses.
    var text: String {
        didSet {
            saveSoon()
            deepenSoon()
        }
    }
    /// True while the language model is looking for mistakes the instant checker cannot see.
    private(set) var deepening = false
    /// The deeper check waiting for typing to pause, or running. A new edit cancels it.
    private var deepTask: Task<Void, Never>?

    /// Once typing pauses, runs the deeper check and shows what it finds as more underlines.
    private func deepenSoon() {
        deepTask?.cancel()
        guard GrammarChecker.deepEnabled else {
            // The job just cancelled will not clear this itself.
            deepening = false
            return
        }
        let snapshot = text
        deepTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1200))
            guard let self, !Task.isCancelled else { return }
            self.deepening = true
            let learned = await self.assistant.checker.deepen(snapshot)
            if !Task.isCancelled { self.deepening = false }
            // What was learned is kept paragraph by paragraph, so it is worth showing even if the draft has
            // changed elsewhere since (and a newer check skips a paragraph this one was already reading).
            if learned { self.recheck += 1 }
            if !Task.isCancelled { await self.assistant.detectTone(snapshot) }
        }
    }
    /// What the editor's last check found, kept here for the counts, Fix all and the test hooks.
    var issues: [WritingIssue] = []
    /// Bumped to make the editor check again when something other than typing changed the answer.
    var recheck = 0
    private let app: AppModel
    let assistant: WritingAssistant
    /// The save waiting for typing to pause.
    private var saveTask: Task<Void, Never>?

    init(app: AppModel, assistant: WritingAssistant) {
        self.app = app
        self.assistant = assistant
        text = (try? app.engine.setting("writeDraft", as: String.self)) ?? ""
        Self.shared = self

        LinkHandler.commands["write-set"] = { [weak self] q in self?.text = q["text"] ?? "" }
        LinkHandler.commands["write-fixall"] = { [weak self] _ in self?.fixAll() }
        LinkHandler.commands["write-caret"] = { q in CheckedTextEditor.Coordinator.current?.setCaret(Int(q["at"] ?? "0") ?? 0) }
        LinkHandler.commands["write-deep"] = { [weak self] q in
            GrammarChecker.deepEnabled = q["on"] != "0"
            self?.deepenSoon()
        }
        LinkHandler.commands["write-run"] = { [weak self] q in
            guard let self, let task = Self.task(named: q["task"] ?? "") else { return }
            self.assistant.run(task, on: self.text)
        }
        LinkHandler.commands["write-accept"] = { [weak self] _ in self?.acceptResult() }
        LinkHandler.commands["write-act"] = { [weak self] q in
            guard let self, let i = Int(q["issue"] ?? "0"), self.issues.indices.contains(i) else { return }
            let issue = self.issues[i]
            switch q["do"] {
            case "dismiss": try? app.engine.dismiss(ruleKey: issue.rule, text: issue.flagged(in: self.text))
            case "rule": try? app.engine.dismiss(ruleKey: issue.rule, text: nil)
            case "dictionary": _ = try? app.engine.addWord(issue.flagged(in: self.text))
            default: if let fix = issue.suggestions.first { self.text = Proofreading.apply(fix, to: issue, in: self.text).text }
            }
            self.recheck += 1
        }
        LinkHandler.stateProviders["write"] = { [weak self] in
            guard let self else { return [:] }
            return [
                "text": self.text,
                "issues": self.issues.map { "\($0.category.rawValue):\($0.flagged(in: self.text)):\($0.suggestions.first?.text ?? "")" },
                "result": self.assistant.result, "busy": self.assistant.busy != nil, "deepening": self.deepening,
                "tone": self.assistant.toneFor == self.text ? self.assistant.tone : "",
            ]
        }
    }

    /// The rewrite a debug link names ("fix", "shorten", and so on).
    static func task(named name: String) -> WritingTask? {
        switch name {
        case "fix": .fix
        case "casual": .rephrase(.casual)
        case "rephrase": .rephrase(.neutral)
        case "formal": .rephrase(.formal)
        case "shorten": .shorten
        case "writeout", "expand": .writeOut
        case "summarize": .summarize
        default: nil
        }
    }

    /// Applies the first suggestion of every spelling and grammar problem in the draft.
    func fixAll() {
        text = Proofreading.fixAll(issues, in: text)
        recheck += 1
    }

    /// Replaces the draft with the finished rewrite.
    func acceptResult() {
        guard !assistant.result.isEmpty, assistant.busy == nil else { return }
        text = assistant.result
        assistant.clear()
        recheck += 1
    }

    /// Saves the draft to the Library as a note.
    func saveAsNote() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try Library(store: app.store).save(SavedItem(kind: .note, body: trimmed))
            app.banner = nil
        } catch { app.report(error, doing: "save the note") }
    }

    /// Saves the draft half a second after the last change, so it survives a restart.
    private func saveSoon() {
        saveTask?.cancel()
        let snapshot = text
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            if !Task.isCancelled { try? self?.app.engine.setSetting("writeDraft", snapshot) }
        }
    }
}

/// The page for checking a draft: counts of what was found, the rewrite buttons, the editor, and the
/// result of a rewrite beside it.
struct WritePage: View {
    @Environment(AppModel.self) private var app
    @Environment(WriteModel.self) private var model
    @Environment(UnderlineController.self) private var underlines
    @State private var showOptions = false
    @State private var saved = false

    var body: some View {
        @Bindable var model = model
        Page("Check a draft", subtitle: "Spelling, grammar and rephrasing. Chirp improves your words; it does not write for you") {
            VStack(alignment: .leading, spacing: 10) {
                toolbar
                HStack(alignment: .top, spacing: 14) {
                    editor
                    if model.assistant.task != nil { resultPanel.frame(width: 340) }
                }
            }
            .padding(.horizontal, PageLayout.gutter)
            .padding(.top, 16)
            .padding(.bottom, 20)
        }
        .onAppear(perform: takeFocus)
        .onChange(of: app.focus) { takeFocus() }
    }

    /// Opening a saved note from search puts it in the editor.
    private func takeFocus() {
        guard let item = app.focus, item.kind == .note else { return }
        model.text = item.body
        model.recheck += 1
        app.focus = nil
    }

    /// The row above the editor: how many problems of each kind, Fix all, and the rewrites.
    private var toolbar: some View {
        HStack(spacing: 8) {
            ForEach(IssueCategory.allCases, id: \.self) { category in
                let count = model.issues.filter { $0.category == category }.count
                HStack(spacing: 4) {
                    Circle().fill(Color(nsColor: category.color)).frame(width: 7, height: 7)
                    Text("\(count) \(category.title.lowercased())").font(.rowMeta).fixedSize().foregroundStyle(count == 0 ? Color.quiet : Color.ink)
                }
                .accessibilityElement(children: .combine)
            }
            if model.deepening {
                ProgressView().controlSize(.small)
                Text("Checking grammar").font(.rowMeta).foregroundStyle(Color.quiet).fixedSize()
            }
            if !model.assistant.tone.isEmpty, model.assistant.toneFor == model.text {
                Text("Sounds \(model.assistant.tone)").font(.rowMeta).foregroundStyle(Color.quiet).fixedSize()
                    .help("How this reads to someone else, judged on this Mac by the language model.")
                    .accessibilityIdentifier("write.tone")
            }
            Button("Fix all") { model.fixAll() }
                .disabled(!model.issues.contains { $0.category != .style && !$0.suggestions.isEmpty && !Proofreading.likelyName($0, in: model.text) })
                .help("Apply every spelling and grammar fix")
                .accessibilityIdentifier("write.fixAll")
            Spacer()
            let empty = model.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            Button("Proofread") { run(.fix) }.disabled(empty)
                .help("A slower, deeper check with the language model. Shows every change before you accept it.")
            Menu("Rewrite") {
                Button("Rephrase, same tone") { run(.rephrase(.neutral)) }
                Button("More casual") { run(.rephrase(.casual)) }
                Button("More formal") { run(.rephrase(.formal)) }
                Divider()
                Button("Shorten") { run(.shorten) }
                Button("Write out my notes") { run(.writeOut) }
            }
            .fixedSize().disabled(empty)
            .accessibilityIdentifier("write.rewrite")
            if Features.on(.summarize) { Button("Summarize") { run(.summarize) }.disabled(empty).fixedSize() }
            Button(saved ? "Saved" : "Save as note") {
                model.saveAsNote()
                saved = true
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    saved = false
                }
            }
            .disabled(empty).fixedSize()
            Button {
                showOptions.toggle()
            } label: {
                Label("Options", image: "chirp.options").labelStyle(.iconOnly)
            }
            .help("Options")
            .accessibilityLabel("Options")
            .onChange(of: app.optionsRequest) { showOptions = true }
            .popover(isPresented: $showOptions, arrowEdge: .bottom) { WriteOptions().environment(underlines) }
        }
    }

    /// The checked editor, with a hint while it is empty.
    private var editor: some View {
        @Bindable var model = model
        return ZStack(alignment: .topLeading) {
            CheckedTextEditor(
                text: $model.text, issues: $model.issues, checker: model.assistant.checker, engine: app.engine,
                recheck: model.recheck)
            if model.text.isEmpty {
                Text("Write or paste here. Chirp underlines what it would fix; click an underline to see why.")
                    .foregroundStyle(Color.quiet).padding(.horizontal, 19).padding(.vertical, 14)
                    .allowsHitTesting(false)
            }
        }
        .background(Color.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.ink.opacity(0.08)))
    }

    /// The result of a rewrite, shown as what changed, with buttons to take it or copy it.
    private var resultPanel: some View {
        let assistant = model.assistant
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(assistant.task?.title ?? "").font(.sectionTitle)
                if assistant.busy != nil { ProgressView().controlSize(.small) }
                Spacer()
                Button {
                    assistant.clear()
                } label: {
                    Image("chirp.close")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Close")
            }
            ScrollView {
                if assistant.result.isEmpty {
                    Text(app.banner == nil ? "Working on it…" : "").foregroundStyle(Color.quiet)
                } else if assistant.task == .summarize || assistant.busy != nil {
                    Text(assistant.result).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    DiffText(old: assistant.source, new: assistant.result)
                }
            }
            .accessibilityIdentifier("write.result")
            HStack {
                if assistant.task != .summarize {
                    Button("Replace my text") { model.acceptResult() }
                        .buttonStyle(.borderedProminent)
                        .disabled(assistant.busy != nil || assistant.result.isEmpty)
                        .accessibilityIdentifier("write.replace")
                }
                Button("Copy") { TextInserter.copy(assistant.result) }
                    .disabled(assistant.result.isEmpty)
            }
        }
        .padding(14)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.ink.opacity(0.08)))
    }

    /// Starts a rewrite of the whole draft.
    private func run(_ task: WritingTask) {
        model.assistant.run(task, on: model.text)
    }
}
