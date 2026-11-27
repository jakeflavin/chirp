import ChirpCore
import Foundation

/// What can go wrong with the language model, in words for the user.
public enum LanguageModelError: LocalizedError, Equatable {
    /// The model was asked to work before `load()` finished.
    case notLoaded
    /// The helper process that runs the model went away in the middle of a request (it crashed, or macOS
    /// ended it). The next request starts a fresh one.
    case workerStopped
    /// The helper process stopped answering and was ended.
    case workerHung
    /// The helper has gone away several times in a row; it is left alone for a minute.
    case keepsStopping
    /// The model itself refused the request, with its reason.
    case refused(String)

    public var errorDescription: String? {
        switch self {
        case .notLoaded: "The language model is not loaded yet."
        case .workerStopped: "The language model stopped unexpectedly. Try again."
        case .workerHung: "The language model did not answer. Try again."
        case .keepsStopping: "The language model keeps stopping. Try again in a minute."
        case .refused(let why): why
        }
    }
}

/// The on-device language model (Qwen3.5 via MLX). It only ever transforms text the user supplied:
/// every call takes a fixed instruction from `Prompts` plus the user's own text.
///
/// This is the app's side. The model itself is loaded and run in a helper process (`LanguageWorker`), so
/// a crash in it cannot take the app down, and unloading ends that process and returns all its memory.
public actor LanguageModel {
    /// The helper process and the pipes to it, shared with the search model.
    private let supervisor = LanguageSupervisor.shared
    /// The helper the model was loaded in, by its number. A different helper running means the model has
    /// to be loaded again.
    private var loadedIn: Int?
    /// Which model is in use, or nil when none is. It stays set while a helper that died is waiting to
    /// be replaced: the model still counts as loaded, and the next run starts a fresh helper.
    public private(set) var loadedModelID: String?
    /// The load in progress, if any, and which model it is for. Two loads never run together: on a Mac
    /// with little memory, two models arriving at once would not fit.
    private var loading: (modelID: String, task: Task<Void, Error>)?

    /// Runs take turns with the model: two at once crashed the app (MLX: "Attempting to eval an array
    /// without a primitive"), and each would hold its own working memory on an 8 GB Mac.
    private var turn: TurnGate { supervisor.runGate }

    public init() {}

    /// Whether a model is in use and ready to run.
    public var isLoaded: Bool { loadedModelID != nil }

    /// Called with a line for the log when the helper starts, stops or is ended.
    public func onNote(_ handler: @escaping @Sendable (String) -> Void) { supervisor.note = handler }

    /// Helpers started since launch, and the running one's process id (diagnostics and tests).
    public var workerStarts: Int { supervisor.workerStarts }
    public var workerPID: Int32? { supervisor.workerPID }

    /// TESTING only (debug links): `kill:<n>`, `hang:<n>` or `fail` for the runs that follow; nil for none.
    public func setFault(_ fault: String?) { supervisor.testFault = fault }

    /// Downloads the model if needed and loads it. `progress` reports 0…1. Which model suits this Mac is
    /// decided by the app (`LanguageModelSize` in ChirpCore), which names it here.
    /// Asking for a different model than the one loaded frees that one first.
    /// A caller that arrives while the same model is loading waits for that load; one that wants a
    /// different model waits for it to finish and then loads its own.
    /// `adapterID` is a LoRA adapter on the hub fused into the model as it loads (the summary model).
    public func load(modelID: String, adapterID: String? = nil, progress: (@Sendable (Double) -> Void)? = nil)
        async throws
    {
        let key = Self.key(modelID, adapterID)
        while let current = loading {
            if current.modelID == key { return try await current.task.value }
            _ = try? await current.task.value
        }
        if loadedModelID == key, let running = supervisor.running, running == loadedIn { return }
        let task = Task<Void, Error> {
            // Cleared here, on the actor, before anyone waiting on the task carries on.
            defer { self.loading = nil }
            try await self.loadNow(modelID: modelID, adapterID: adapterID, progress: progress)
        }
        loading = (key, task)
        try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    /// The load itself. Only ever one at a time: see `load`.
    private func loadNow(modelID: String, adapterID: String?, progress: (@Sendable (Double) -> Void)?) async throws {
        await unload()
        await turn.enter()
        defer { turn.leave() }
        try await startHelper(modelID: modelID, adapterID: adapterID, progress: progress)
        loadedModelID = Self.key(modelID, adapterID)
        loadedAdapterID = adapterID
        loadedBaseID = modelID
        progress?(1)
    }

    /// The model and its adapter as one name, for telling loads apart.
    private static func key(_ modelID: String, _ adapterID: String?) -> String { adapterID.map { "\(modelID)+\($0)" } ?? modelID }
    /// The loaded model's own id and its adapter, to load it again in a fresh helper.
    private var loadedBaseID: String?
    private var loadedAdapterID: String?

    /// Makes sure a helper is running (the one the search model is in, if there is one) and loads the
    /// model in it. Call with the turn held.
    private func startHelper(modelID: String, adapterID: String? = nil, progress: (@Sendable (Double) -> Void)?) async throws {
        let helper = try await supervisor.ensureRunning()
        do {
            try await supervisor.load(modelID: modelID, adapterID: adapterID, progress: progress)
            loadedIn = helper
        } catch {
            // A helper that could not load the model is of no use: do not leave it running.
            await supervisor.stopForUnload()
            throw error
        }
    }

    /// Frees the model's memory by ending the helper. Waits for a run in progress to end first, and for
    /// the search model's request in progress. The search model goes with the helper; it is small, and
    /// the next search loads it again in a fresh helper (about a third of a second).
    public func unload() async {
        await turn.enter()
        defer { turn.leave() }
        guard loadedModelID != nil else { return }
        await supervisor.stopForUnload()
        loadedModelID = nil
        loadedIn = nil
    }

    /// Ends the helper at once without waiting, for when the app quits.
    public nonisolated func stopNow() { supervisor.stopNow() }

    /// Runs one instruction over the user's text and returns the result.
    /// `onPartial` receives the text so far as it is produced.
    public func run(
        instructions: String, text: String, maxTokens: Int = 1024, temperature: Float = 0.2,
        onPartial: (@Sendable (String) -> Void)? = nil
    ) async throws -> String {
        try await runCounted(instructions: instructions, text: text, maxTokens: maxTokens, temperature: temperature, onPartial: onPartial).text
    }

    /// What one run produced, with how much went in and came out and whether it ran into `maxTokens`
    /// before the model had finished (the text then stops mid-thought).
    public struct Counted: Sendable, Codable {
        public var text: String
        public var promptTokens: Int
        public var outputTokens: Int
        public var hitCap: Bool
        /// The most memory the model's arrays took during the run (the weights included), in megabytes.
        public var peakMegabytes: Int = 0
        /// Seconds spent reading the prompt (prefill) and writing the answer, as the library times them.
        public var promptSeconds: Double = 0
        public var generateSeconds: Double = 0
    }

    /// `run`, also reporting the token counts and whether the answer was cut off by `maxTokens`.
    public func runCounted(
        instructions: String, text: String, maxTokens: Int = 1024, temperature: Float = 0.2,
        onPartial: (@Sendable (String) -> Void)? = nil
    ) async throws -> Counted {
        await turn.enter()
        defer { turn.leave() }
        // Cancelled while it waited its turn: nothing to do.
        try Task.checkCancellation()
        guard loadedModelID != nil, let modelID = loadedBaseID else { throw LanguageModelError.notLoaded }
        // The helper died during an earlier request: this one starts a fresh helper. One start a
        // request, never a loop.
        if supervisor.running != loadedIn || loadedIn == nil { try await startHelper(modelID: modelID, adapterID: loadedAdapterID, progress: nil) }
        let request = LanguageRunRequest(instructions: instructions, text: text, maxTokens: maxTokens, temperature: temperature, fault: supervisor.testFault)
        let written = PartialText()
        let counted = try await supervisor.run(request) { piece in
            guard let onPartial else { return }
            onPartial(Self.stripThinking(written.add(piece)))
        }
        supervisor.succeeded()
        return counted
    }

    /// Several requests written together in one batch of the loaded model (`BatchedGeneration.swift`). `onItem` gets
    /// each answer by its index as soon as its row is done, in whatever order they finish. Takes one turn with the model
    /// for the whole batch. Throws `refused` when the model cannot be batched; the caller then runs them one at a time.
    public func runBatch(
        _ requests: [(instructions: String, text: String, maxTokens: Int)], sharePrefix: Bool = true,
        onItem: @escaping @Sendable (Int, Counted) -> Void
    ) async throws {
        await turn.enter()
        defer { turn.leave() }
        try Task.checkCancellation()
        guard loadedModelID != nil, let modelID = loadedBaseID else { throw LanguageModelError.notLoaded }
        if supervisor.running != loadedIn || loadedIn == nil { try await startHelper(modelID: modelID, adapterID: loadedAdapterID, progress: nil) }
        let request = LanguageBatchRequest(items: requests.map { LanguageBatchItem(instructions: $0.instructions, text: $0.text, maxTokens: $0.maxTokens) }, sharePrefix: sharePrefix)
        try await supervisor.runBatch(request, onItem: onItem)
        supervisor.succeeded()
    }

    /// Removes any `<think>…</think>` block a reasoning model emits before its answer.
    static func stripThinking(_ s: String) -> String {
        var t = s
        while let open = t.range(of: "<think>") {
            if let close = t.range(of: "</think>", range: open.upperBound..<t.endIndex) {
                t.removeSubrange(open.lowerBound..<close.upperBound)
            } else {
                t.removeSubrange(open.lowerBound..<t.endIndex)
            }
        }
        return t
    }
}

/// The answer so far, put together from the pieces the helper sends.
private final class PartialText: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""
    func add(_ piece: String) -> String { lock.withLock { text += piece; return text } }
}
