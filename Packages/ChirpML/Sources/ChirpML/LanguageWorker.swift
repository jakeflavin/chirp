import ChirpCore
import Darwin
import Foundation

// The helper for the models that run on MLX: the language model, the search model and the sentence checker.
// It is built on `ModelHelper` like the other helpers: the app's own executable started again with
// `LanguageWorker.flag`, numbered requests and replies on its pipes, a limit on silence and on restarts.
//
// The three models share one helper, one MLX runtime and one capped buffer pool. Two runs of the language
// model at once crashed MLX, so its runs take turns (`LanguageSupervisor.runGate`); the search model and the
// sentence checker take turns on a lane of their own (`embedGate`), so a search typed during a summary does
// not wait for it. A helper that died is not restarted by itself: the next request starts a fresh one.

/// The payload of an `embed` request: the texts to turn into vectors, already prefixed for a query.
struct EmbedRequest: Codable, Sendable {
    var texts: [String]
    /// TESTING only (set by a debug link): `kill-embed` ends the worker as it starts on these texts.
    var fault: String?
}

/// The payload of a `check` request: groups of claims, each scored against every chunk of its group's text.
struct CheckRequest: Codable, Sendable {
    struct Group: Codable, Sendable {
        var chunks: [String]
        var claims: [String]
    }
    var groups: [Group]
}

/// The answer to a `check` request: for each group, each claim's best score over the chunks; and the most MLX held.
struct CheckReply: Codable, Sendable {
    var scores: [[Double]]
    var peakMegabytes: Int
}

/// The payload of a `load` request.
struct LanguageLoadRequest: Codable, Sendable {
    var modelID: String
    /// A LoRA adapter on the hub (PEFT format) fused into the model as it loads, or nil.
    var adapterID: String? = nil
}

/// The payload of a `run` request.
struct LanguageRunRequest: Codable, Sendable {
    var instructions: String
    var text: String
    var maxTokens: Int
    var temperature: Float
    /// TESTING only (set by a debug link, never otherwise): `kill:<n>` ends the worker after n pieces of
    /// the answer, `hang:<n>` stops answering after n, `fail` refuses the run.
    var fault: String?
}

/// The requests the helper answers, by the name each travels under.
enum LanguageOp {
    static let load = "load", run = "run", runBatch = "runBatch"
    static let embedLoad = "embedLoad", embed = "embed", embedUnload = "embedUnload"
    static let checkLoad = "checkLoad", check = "check", checkUnload = "checkUnload"
}

/// The child process: loads the models it is told to and runs what it is sent, until the app closes the pipe.
public enum LanguageWorker {
    /// The first argument that makes the app's executable run as the language worker instead of as the app.
    public static let flag = "--language-worker"

    /// Whether this process was launched as the language worker. Checked before the app starts.
    public static var isWorkerInvocation: Bool {
        CommandLine.arguments.count > 1 && CommandLine.arguments[1] == flag
    }

    /// The worker's whole life: answer requests from standard input on standard output, and exit when the
    /// app closes its end (`HelperWorker.serve`). An error is sent back as a `failed` reply, not a crash, so
    /// the app can tell a refused run from a dead worker.
    public static func run() -> Never {
        let engine = LanguageEngine()
        let search = EmbedEngine()
        let checker = CheckEngine()
        let nothing = (json: Data(), blob: Data())
        HelperWorker.serve(streaming: [
            LanguageOp.load: { json, _, progress, _ in
                let request = try JSONDecoder().decode(LanguageLoadRequest.self, from: json)
                try await engine.load(modelID: request.modelID, adapterID: request.adapterID) { progress($0) }
                return nothing
            },
            // Each piece of the answer goes back as it is written; the counts come with the answer.
            LanguageOp.run: { json, _, _, partial in
                let request = try JSONDecoder().decode(LanguageRunRequest.self, from: json)
                let fault = LanguageFault(request.fault)
                if fault.fails { throw LanguageModelError.refused("injected failure") }
                let pieces = PieceCount()
                let counted = try await engine.runCounted(
                    instructions: request.instructions, text: request.text, maxTokens: request.maxTokens,
                    temperature: request.temperature
                ) { piece in
                    fault.apply(after: pieces.next())
                    partial(Data(piece.utf8))
                }
                return (try JSONEncoder().encode(counted), Data())
            },
            // Each answer of the batch goes back as soon as its row is done, as a piece; the answer itself is empty.
            LanguageOp.runBatch: { json, _, _, partial in
                let request = try JSONDecoder().decode(LanguageBatchRequest.self, from: json)
                do {
                    try await engine.runBatch(request.items, sharePrefix: request.sharePrefix) { index, counted in
                        if let piece = try? JSONEncoder().encode(LanguageBatchReply(index: index, counted: counted)) { partial(piece) }
                    }
                } catch let error as CancellationError {
                    throw error
                } catch {
                    throw LanguageModelError.refused("batch: \(error)")
                }
                return nothing
            },
            LanguageOp.embedLoad: { json, _, progress, _ in
                try await search.load(modelID: String(decoding: json, as: UTF8.self)) { progress($0) }
                return nothing
            },
            LanguageOp.embed: { json, _, _, _ in
                let request = try JSONDecoder().decode(EmbedRequest.self, from: json)
                LanguageFault(request.fault).applyToEmbed()
                return (try JSONEncoder().encode(try await search.embed(request.texts)), Data())
            },
            LanguageOp.embedUnload: { _, _, _, _ in
                await search.unload()
                return nothing
            },
            LanguageOp.checkLoad: { json, _, _, _ in
                try await checker.load(directory: URL(fileURLWithPath: String(decoding: json, as: UTF8.self)))
                return nothing
            },
            LanguageOp.check: { json, _, _, _ in
                let request = try JSONDecoder().decode(CheckRequest.self, from: json)
                return (try JSONEncoder().encode(try await checker.score(request)), Data())
            },
            LanguageOp.checkUnload: { _, _, _, _ in
                await checker.unload()
                return nothing
            },
        ], priority: .userInitiated)
    }
}

/// Counts the pieces of an answer as they are written (the callback runs on the model's actor, one at a time).
private final class PieceCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func next() -> Int { lock.withLock { count += 1; return count } }
}

/// A fault a test asked for, carried in the run request. See `LanguageRunRequest.fault`.
struct LanguageFault: Sendable {
    var killAfter: Int?
    var hangAfter: Int?
    var fails = false
    var killsEmbed = false

    init(_ text: String?) {
        let parts = (text ?? "").split(separator: ":", maxSplits: 1).map(String.init)
        switch parts.first {
        case "kill": killAfter = Int(parts.count > 1 ? parts[1] : "") ?? 1
        case "hang": hangAfter = Int(parts.count > 1 ? parts[1] : "") ?? 1
        case "fail": fails = true
        case "kill-embed": killsEmbed = true
        default: break
        }
    }

    /// For the search lane: `kill-embed` ends the worker as it starts on a batch of texts.
    func applyToEmbed() {
        if killsEmbed { kill(getpid(), SIGKILL) }
    }

    /// Called with how many pieces of the answer have been written so far.
    func apply(after pieces: Int) {
        // SIGKILL: the worker is gone at once, as when macOS ends it for memory, and nothing is reported.
        if let killAfter, pieces >= killAfter { kill(getpid(), SIGKILL) }
        if let hangAfter, pieces >= hangAfter { while true { sleep(1000) } }
    }
}

/// The app's side: owns the one helper (a `ModelHelper`). `LanguageModel`, `Embedder` and `FactChecker` share
/// it; each sends one request at a time on its own lane, and says when the helper may be ended.
final class LanguageSupervisor: @unchecked Sendable {
    /// The one supervisor: there is one helper for all MLX work.
    static let shared = LanguageSupervisor()

    /// Runs of the language model take turns here (two at once crashed MLX; see `LanguageModel`).
    let runGate = TurnGate()
    /// The search model's requests take turns here, apart from the language model's runs, so a search
    /// typed during a summary does not wait for the summary's current step.
    let embedGate = TurnGate()
    /// Starting and stopping the helper, one at a time, and checking what it holds before ending it.
    private let startGate = TurnGate()

    /// The helper process and its pipes. Its process and its requests run at user-initiated priority, as the
    /// language helper always has: a step below the other helpers.
    private let helper = ModelHelper(arguments: [LanguageWorker.flag], what: "language model", qualityOfService: .userInitiated)

    /// Guards everything below; only ever held for a moment.
    private let lock = NSLock()
    /// The helper the language model was loaded in, by its number. A helper with another number (a fresh one
    /// after a death or an unload) does not hold it.
    private var languageLoadedIn: Int?
    /// TESTING only: a fault for the requests that follow to ask the worker for. Set by a debug link.
    private var faultText: String?
    var testFault: String? {
        get { lock.withLock { faultText } }
        set { lock.withLock { faultText = newValue } }
    }
    /// Called with a line for the log about what this supervisor decides (the helper's own starts, stops and
    /// deaths go to `ModelHelper.log`).
    private var noteHandler: (@Sendable (String) -> Void)?

    var note: (@Sendable (String) -> Void)? {
        get { lock.withLock { noteHandler } }
        set { lock.withLock { noteHandler = newValue } }
    }

    /// Seconds a load may go without a word from the worker (a download reports as it goes).
    static let loadSilence: Double = 180
    /// Seconds a run may go without a word: the prompt is read in silence, then pieces come steadily.
    static let runSilence: Double = 120
    /// Seconds the search model may go without a word.
    static let embedSilence: Double = 60
    /// Seconds an unload may take.
    static let unloadSilence: Double = 10

    /// Whether a worker is running.
    var isRunning: Bool { helper.running != nil }
    /// Workers started since launch (diagnostics).
    var workerStarts: Int { helper.helperStarts }
    /// The running worker's process id (diagnostics and tests).
    var workerPID: pid_t? { helper.helperPID }

    /// The running worker's number, or nil when there is none.
    var running: Int? { helper.running }

    /// Whether the language model is loaded in the running worker.
    private var languageLoaded: Bool {
        guard let running = helper.running else { return false }
        return lock.withLock { languageLoadedIn == running }
    }

    /// Makes sure a worker is running, starting one if need be, and returns its number. Refuses while a
    /// worker that kept dying is being left alone.
    func ensureRunning() async throws -> Int {
        await startGate.enter()
        defer { startGate.leave() }
        do { return try await helper.ensureRunning() } catch { throw Self.languageError(error) }
    }

    /// A request finished: the worker is working.
    func succeeded() { helper.succeeded() }

    /// Ends the worker for an unload, after the search model's request in progress (if any) has finished.
    /// Call with the run gate held.
    func stopForUnload() async {
        await embedGate.enter()
        defer { embedGate.leave() }
        await startGate.enter()
        defer { startGate.leave() }
        await stop()
    }

    /// Asks the worker to load the model. `progress` reports 0…1 while it downloads.
    func load(modelID: String, adapterID: String? = nil, progress: (@Sendable (Double) -> Void)?) async throws {
        let number = helper.running
        _ = try await call(
            LanguageOp.load, json: try JSONEncoder().encode(LanguageLoadRequest(modelID: modelID, adapterID: adapterID)),
            silence: Self.loadSilence, progress: progress)
        lock.withLock { languageLoadedIn = number }
    }

    /// Runs one request in the worker. `onPiece` receives each piece of the answer as it is written. When
    /// the calling task is cancelled the worker is told to stop, and is ended five seconds later if it has not
    /// (`ModelHelper.call`).
    func run(_ request: LanguageRunRequest, onPiece: @escaping @Sendable (String) -> Void) async throws -> LanguageModel.Counted {
        let answer = try await call(
            LanguageOp.run, json: try JSONEncoder().encode(request), silence: Self.runSilence,
            partial: { onPiece(String(decoding: $0, as: UTF8.self)) }, cancellable: true)
        return try JSONDecoder().decode(LanguageModel.Counted.self, from: answer.json)
    }

    /// Runs several requests as one batch in the worker. `onItem` gets each request's answer, by its index, as soon as it
    /// is done. Cancelling works as for `run`.
    func runBatch(_ request: LanguageBatchRequest, onItem: @escaping @Sendable (Int, LanguageModel.Counted) -> Void) async throws {
        _ = try await call(
            LanguageOp.runBatch, json: try JSONEncoder().encode(request), silence: Self.runSilence,
            partial: { piece in
                guard let item = try? JSONDecoder().decode(LanguageBatchReply.self, from: piece) else { return }
                onItem(item.index, item.counted)
            }, cancellable: true)
    }

    /// Closes the worker's input, gives it a moment to exit by itself, then kills it if it is still there.
    /// All of the model's memory goes back to macOS with it.
    func stop() async {
        await helper.stop()
        lock.withLock { languageLoadedIn = nil }
    }

    /// Ends the worker at once, from any thread, without waiting: for when the app quits.
    func stopNow() { helper.stopNow() }

    // MARK: The search model's lane

    /// Asks the worker to load the search model.
    func embedLoad(modelID: String, progress: (@Sendable (Double) -> Void)?) async throws {
        _ = try await call(LanguageOp.embedLoad, json: Data(modelID.utf8), silence: Self.loadSilence, progress: progress)
    }

    /// Turns texts into vectors in the worker.
    func embed(_ texts: [String]) async throws -> [[Float]] {
        let answer = try await call(
            LanguageOp.embed, json: try JSONEncoder().encode(EmbedRequest(texts: texts, fault: testFault)), silence: Self.embedSilence)
        succeeded()
        return try JSONDecoder().decode([[Float]].self, from: answer.json)
    }

    /// Ends worker number `number` if it is still the one running and holds only the search model.
    /// Returns whether it was ended.
    func endIfOnlySearch(_ number: Int) async -> Bool {
        await startGate.enter()
        defer { startGate.leave() }
        guard helper.running == number, !languageLoaded else { return false }
        note?("language worker ended: the search model sat unused")
        await stop()
        return true
    }

    /// Lets the search model go. With the language model loaded the worker stays and only drops it;
    /// otherwise nothing is left to keep the worker for, and it is ended.
    func embedUnload() async {
        if languageLoaded {
            _ = try? await call(LanguageOp.embedUnload, silence: Self.unloadSilence)
        } else {
            await startGate.enter()
            defer { startGate.leave() }
            await stop()
        }
    }

    // MARK: The sentence checker's lane

    /// Loads the sentence checker from a folder, scores the request, and lets the checker go, in one call. The
    /// caller has put the language model away first: one model at a time.
    func check(directory: String, request: CheckRequest) async throws -> CheckReply {
        _ = try await call(LanguageOp.checkLoad, json: Data(directory.utf8), silence: Self.loadSilence)
        let answer = try await call(LanguageOp.check, json: try JSONEncoder().encode(request), silence: Self.embedSilence * 3)
        let reply = try JSONDecoder().decode(CheckReply.self, from: answer.json)
        succeeded()
        // The checker goes again at once; the worker stays for the language model.
        _ = try? await call(LanguageOp.checkUnload, silence: Self.unloadSilence)
        return reply
    }

    // MARK: Plumbing

    /// One request to the running worker. Never starts one: the callers do that with `ensureRunning`, so the
    /// one start a request is allowed happens where they decide. An answer does not count as the worker
    /// working by itself; the callers say when it does (`succeeded`). Errors come back as `LanguageModelError`.
    /// Only a `cancellable` request (a run) is stopped when its caller is cancelled; a load, a search or a check
    /// carries on to its answer. For a run, a worker ended while the caller was being cancelled is a cancel.
    private func call(
        _ op: String, json: Data = Data(), silence: Double, progress: (@Sendable (Double) -> Void)? = nil,
        partial: (@Sendable (Data) -> Void)? = nil, cancellable: Bool = false
    ) async throws -> HelperFrame {
        do {
            return try await helper.call(
                op, json: json, silence: silence, starting: false, progress: progress, partial: partial, succeeds: false,
                cancels: cancellable)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if cancellable, Task.isCancelled { throw CancellationError() }
            throw Self.languageError(error)
        }
    }

    /// A helper's error, said of the language model.
    private static func languageError(_ error: Error) -> Error {
        guard let failure = error as? HelperError else { return error }
        switch failure {
        case .stopped: return LanguageModelError.workerStopped
        case .noAnswer: return LanguageModelError.workerHung
        case .keepsStopping: return LanguageModelError.keepsStopping
        case .refused(let why): return LanguageModelError.refused(why)
        }
    }
}
