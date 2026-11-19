import ChirpCore
import ChirpHarper
import Foundation
import Observation

/// Spelling and grammar checks by Harper (runs in milliseconds, no language model).
/// The user's dictionary words are never flagged, and dismissed suggestions stay dismissed.
final class GrammarChecker: @unchecked Sendable {
    private let engine: PersonalLanguage
    /// Checks run here, off the main thread, one at a time.
    private let queue = DispatchQueue(label: "chirp.grammar", qos: .userInitiated)
    /// Harper's checker, built on first use and rebuilt when the dictionary or spelling variant changes.
    private var checker: OpaquePointer?
    /// The dictionary and spelling variant the checker was built with, to tell when it is out of date.
    private var signature = ""

    // The deeper check: the language model proofreads a paragraph and each change becomes a suggestion.
    // Results are remembered per paragraph, so the instant check can include them without waiting.
    private let deepLock = NSLock()
    /// What the deeper check found, by paragraph text. Positions are within the paragraph.
    private var deep: [String: [WritingIssue]] = [:]
    /// Paragraphs the language model is reading right now, so two checks at once do not both read the same one.
    private var deepInFlight: Set<String> = []
    /// Proofreads one paragraph with the language model. Set by the app once the model is available.
    var deepRunner: (@Sendable (String) async -> String?)?

    /// Whether the deeper check runs in Chirp's own editor and panel.
    static var deepEnabled: Bool {
        get {
            UserDefaults.standard.object(forKey: "deepChecks") as? Bool
                ?? !ProcessInfo.processInfo.arguments.contains("--ui-testing")
        }
        set { UserDefaults.standard.set(newValue, forKey: "deepChecks") }
    }
    /// Whether it also runs on text fields in other apps. Off by default on Macs with little memory,
    /// because it keeps the language model loaded while you type.
    static var deepInOtherApps: Bool {
        get { UserDefaults.standard.object(forKey: "deepChecksEverywhere") as? Bool ?? (ProcessInfo.processInfo.physicalMemory >= 15 * 1_073_741_824) }
        set { UserDefaults.standard.set(newValue, forKey: "deepChecksEverywhere") }
    }

    /// Paragraphs of a text with where each starts (UTF-16).
    private static func paragraphs(_ text: String) -> [(text: String, offset: Int)] {
        var out: [(String, Int)] = []
        var offset = 0
        for part in text.components(separatedBy: "\n") {
            out.append((part, offset))
            offset += (part as NSString).length + 1
        }
        return out
    }

    /// Runs the deeper check on any paragraph of `text` not yet looked at. Returns true if it found
    /// out anything new, in which case checking the text again will include it.
    func deepen(_ text: String) async -> Bool {
        guard let deepRunner else { return false }
        var learned = false
        for (paragraph, _) in Self.paragraphs(text) {
            // The text has changed since this was asked for: stop, and let the newer check carry on.
            if Task.isCancelled { break }
            let trimmed = paragraph.trimmingCharacters(in: .whitespaces)
            // Sentences, not fragments or pasted walls of text.
            guard trimmed.count >= 15, trimmed.count <= 1500, trimmed.contains(" ") else { continue }
            // Skip a paragraph already read, or being read by another check; otherwise claim it.
            let claimed = deepLock.withLock { () -> Bool in
                if deep[paragraph] != nil || deepInFlight.contains(paragraph) { return false }
                deepInFlight.insert(paragraph)
                return true
            }
            guard claimed else { continue }
            guard let corrected = await deepRunner(paragraph) else {
                deepLock.withLock { _ = deepInFlight.remove(paragraph) }
                continue
            }
            let issues = Proofreading.modelIssues(original: paragraph, corrected: corrected)
            deepLock.withLock {
                deepInFlight.remove(paragraph)
                if deep.count > 400 { deep.removeAll() }
                deep[paragraph] = issues
            }
            learned = learned || !issues.isEmpty
        }
        return learned
    }

    init(engine: PersonalLanguage) {
        self.engine = engine
    }

    deinit {
        if let checker { chirp_checker_free(checker) }
    }

    /// Issues in `text`, minus anything the user dismissed.
    func check(_ text: String) async -> [WritingIssue] {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.lint(text)) }
        }
    }

    /// The same check, waited for on the calling thread. It still takes its turn with the other checks,
    /// because the checker must not be used by two threads at once.
    func checkNow(_ text: String) -> [WritingIssue] {
        queue.sync { lint(text) }
    }

    /// The check itself. Only ever run on the checking queue.
    private func lint(_ text: String) -> [WritingIssue] {
        guard !text.isEmpty else { return [] }
        prepare()
        guard let checker, let raw = text.withCString({ chirp_checker_lint(checker, $0) }) else { return [] }
        defer { chirp_string_free(raw) }
        var issues = Proofreading.decode(String(cString: raw))
        // Add what the deeper check already found for these paragraphs. Where both flag the same words,
        // the instant checker's suggestion is kept.
        for (paragraph, offset) in Self.paragraphs(text) {
            guard let found = deepLock.withLock({ deep[paragraph] }) else { continue }
            for var issue in found {
                issue.start += offset
                issue.end += offset
                issues.append(issue)
            }
        }
        // A snippet's cue that was typed is offered like a fix, where the user has that switched on.
        if Self.offersSnippets {
            issues.append(contentsOf: SnippetOffers.issues(in: text, snippets: (try? engine.snippets()) ?? []))
        }
        return Proofreading.visible(issues, in: text, dismissed: (try? engine.dismissedRules()) ?? [])
    }

    /// "Offer snippets as I type" (Settings › Writing). On unless switched off.
    static var offersSnippets: Bool {
        get { UserDefaults.standard.object(forKey: "offerSnippets") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "offerSnippets") }
    }

    /// Rebuilds the checker when the dictionary or spelling variant changed.
    private func prepare() {
        let words = ((try? engine.dictionary()) ?? []).flatMap { $0.term.split(separator: " ").map(String.init) }
        let british = (try? engine.profile().spelling) == .british
        let newSignature = (british ? "gb|" : "us|") + words.joined(separator: "\n")
        guard checker == nil || newSignature != signature else { return }
        if let checker { chirp_checker_free(checker) }
        checker = words.joined(separator: "\n").withCString { chirp_checker_new(british ? 1 : 0, $0) }
        signature = newSignature
    }
}

/// Runs the language model over the user's own text: fix, rephrase, shorten, expand, summarize.
@MainActor
@Observable
final class WritingAssistant {
    /// The task running now, or nil when idle.
    private(set) var busy: WritingTask?
    /// The result while it streams in and after it finishes.
    private(set) var result = ""
    /// The text the result was made from, for showing what changed.
    private(set) var source = ""
    /// The task whose result is showing. Stays set after it finishes, until cleared.
    private(set) var task: WritingTask?
    /// The running job, so a new task or a clear can cancel it.
    private var work: Task<Void, Never>?
    /// Counts the tasks started, so a job that was replaced can tell it is no longer the current one.
    @ObservationIgnored private var runID = 0
    /// How the text last looked at reads to someone else, e.g. "friendly and direct".
    private(set) var tone = ""
    private(set) var toneFor = ""

    /// Works out how `text` comes across. Short notes are skipped: there is not enough to judge.
    func detectTone(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard GrammarChecker.deepEnabled, trimmed.count >= 80, toneFor != text else { return }
        guard (try? await models.ensure(.language)) != nil, let prompts = try? Prompts(engine: app.engine),
            let out = try? await models.language.run(
                instructions: prompts.toneInstructions(), text: String(trimmed.prefix(3000)), maxTokens: 16, temperature: 0)
        else { return }
        // One short line, whatever else the model adds.
        let line = (out.split(whereSeparator: \.isNewline).first.map(String.init) ?? "")
            .trimmingCharacters(in: CharacterSet(charactersIn: " .\"'")).lowercased()
        guard !line.isEmpty, line.count <= 40 else { return }
        tone = line
        toneFor = text
    }

    let app: AppModel
    let models: ModelCenter
    let checker: GrammarChecker

    init(app: AppModel, models: ModelCenter) {
        self.app = app
        self.models = models
        checker = GrammarChecker(engine: app.engine)
        checker.deepRunner = { [weak app, weak models] paragraph in
            await MainActor.run { () -> Task<String?, Never> in
                Task { @MainActor in
                    guard let app, let models, (try? await models.ensure(.language)) != nil,
                        let prompts = try? Prompts(engine: app.engine)
                    else { return nil }
                    return try? await models.language.run(
                        instructions: prompts.instructions(for: .fix), text: paragraph,
                        maxTokens: paragraph.count / 2 + 120, temperature: 0)
                }
            }.value
        }
    }

    /// Why the last rewrite is not offered, in a few plain words. Nil while there is one to offer.
    private(set) var refused: String?
    /// What the rule check found wrong with the last rewrite, for the debug state.
    @ObservationIgnored private(set) var lastProblems: [RewriteCheck.Problem] = []

    /// A rewrite as it came through the rule check.
    struct Checked: Sendable {
        /// The rewrite, when it may be offered.
        var text: String?
        /// What was wrong with the last attempt; empty when `text` is offered.
        var problems: [RewriteCheck.Problem]
        /// How many times the model was asked (1, or 2 when the first answer failed the check).
        var tries: Int
        /// The model's first answer, whatever came of it (for the test set).
        var first: String
    }

    /// Runs `task` over `text` with the language model and reads the answer by rule afterwards. An answer
    /// that changes the person, drops a question, answers the text or adds to it is asked for once more
    /// with the broken rule spelled out; if that fails too, nothing is offered.
    func rewriteChecked(
        _ task: WritingTask, text: String, context: WorkContext = WorkContext(), redo: Bool = true,
        partial: (@Sendable (String) -> Void)? = nil
    ) async throws -> Checked {
        try await models.ensure(.language)
        return try await rewriteRuns(task, text: text, context: context, redo: redo, partial: partial)
    }

    /// The model's runs of a rewrite and the rule check over them, on whichever model is loaded.
    private func rewriteRuns(
        _ task: WritingTask, text: String, context: WorkContext, redo: Bool, partial: (@Sendable (String) -> Void)?
    ) async throws -> Checked {
        let prompts = try Prompts(engine: app.engine, context: context)
        let limit = task == .writeOut ? max(400, text.count) : max(256, text.count / 2 + 120)
        let out = try await models.language.run(
            instructions: prompts.instructions(for: task), text: text, maxTokens: limit, temperature: task == .fix ? 0 : 0.3, onPartial: partial)
        let first = RewriteCheck.tidy(out)
        var problems = RewriteCheck.problems(task: task, original: text, result: first)
        if problems.isEmpty { return Checked(text: first, problems: [], tries: 1, first: first) }
        Log.write("write", "rewrite: \(task.title) failed the check (\(problems.map(\.rawValue).joined(separator: ", ")))")
        guard redo else { return Checked(text: nil, problems: problems, tries: 1, first: first) }
        try Task.checkCancellation()
        // Asked once more with the broken rule spelled out. A text that came back unchanged is asked for
        // with a little more freedom; anything else with none.
        let same = problems == [.unchanged] || problems == [.notShorter]
        let again = try await models.language.run(
            instructions: prompts.instructions(for: task) + "\n" + RewriteCheck.reminder(for: problems), text: text, maxTokens: limit,
            temperature: same ? 0.5 : 0, onPartial: nil)
        let second = RewriteCheck.tidy(again)
        problems = RewriteCheck.problems(task: task, original: text, result: second)
        if problems.isEmpty { return Checked(text: second, problems: [], tries: 2, first: first) }
        Log.write("write", "rewrite: \(task.title) failed the check again (\(problems.map(\.rawValue).joined(separator: ", "))); not offered")
        return Checked(text: nil, problems: problems, tries: 2, first: first)
    }

    /// Runs `task` on `text` with the language model, replacing any task already running. The result fills
    /// in as it is written; `completion` gets the finished text. A rewrite that fails the rule check is not
    /// offered: `refused` says so instead.
    func run(_ task: WritingTask, on text: String, context: WorkContext = WorkContext(), completion: (@MainActor (String) -> Void)? = nil) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        work?.cancel()
        busy = task
        self.task = task
        source = text
        result = ""
        refused = nil
        lastProblems = []
        app.mood = .thinking
        runID += 1
        let id = runID
        work = Task { [weak self] in
            guard let self else { return }
            defer {
                // A job that was replaced leaves "busy" and the mood to the one that replaced it.
                if self.runID == id {
                    if self.busy == task { self.busy = nil }
                    self.app.mood = .idle
                }
            }
            do {
                let checked = try await self.rewriteChecked(task, text: text, context: context) { partial in
                    Task { @MainActor in if self.runID == id, self.busy == task { self.result = partial } }
                }
                guard !Task.isCancelled, self.runID == id else { return }
                self.lastProblems = checked.problems
                if let out = checked.text {
                    self.result = out
                    completion?(out)
                } else {
                    self.result = ""
                    self.refused = RewriteCheck.message(task: task, problems: checked.problems)
                }
            } catch is CancellationError {
            } catch {
                self.app.report(error, doing: task.title.lowercased())
            }
        }
    }

    /// Stops any running task and drops its result.
    func clear() {
        work?.cancel()
        busy = nil
        task = nil
        result = ""
        source = ""
        refused = nil
    }
}
