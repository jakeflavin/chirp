import ChirpCore
import Foundation

/// What can go wrong with the search model, in words for the user.
public enum EmbedderError: LocalizedError {
    /// The model was asked to work before `load()` finished.
    case notLoaded
    /// The helper process that runs the model went away in the middle of a request. The next one starts
    /// a fresh helper.
    case stopped
    /// The helper stopped answering and was ended.
    case noAnswer
    /// The helper has gone away several times in a row; it is left alone for a minute.
    case keepsStopping
    /// The model itself refused the request, with its reason.
    case refused(String)

    public var errorDescription: String? {
        switch self {
        case .notLoaded: "The search model is not loaded yet."
        case .stopped: "The search model stopped unexpectedly. Try again."
        case .noAnswer: "The search model did not answer. Try again."
        case .keepsStopping: "The search model keeps stopping. Try again in a minute."
        case .refused(let why): why
        }
    }

    /// The same failure, said of the search model.
    init(_ error: LanguageModelError) {
        switch error {
        case .notLoaded: self = .notLoaded
        case .workerStopped: self = .stopped
        case .workerHung: self = .noAnswer
        case .keepsStopping: self = .keepsStopping
        case .refused(let why): self = .refused(why)
        }
    }
}

/// Turns text into vectors so notes can be found by meaning (bge-small-en-v1.5, MIT).
///
/// This is the app's side. The model itself is loaded and run in the helper process the language model
/// uses (`LanguageWorker`, `EmbedEngine`), so a fault in it cannot take the app down.
public actor Embedder {
    /// The model on Hugging Face. Vectors from different models cannot be compared, so changing this
    /// means everything already indexed has to be embedded again.
    public static let modelID = "BAAI/bge-small-en-v1.5"
    /// The commit of that repository that is loaded, pinned so a change on the hub never reaches a Mac unasked.
    static let revision = "5c38ec7c405ec4b44b94cc5a9bb96e735b38267a"
    /// bge models expect this in front of a search query (not in front of the passages).
    static let queryPrefix = "Represent this sentence for searching relevant passages: "
    /// The helper process and the pipes to it, shared with the language model.
    private let supervisor = LanguageSupervisor.shared
    /// True from `load()` to `unload()`. The model counts as loaded even while the helper it was in has
    /// gone (ended with the language model, or died): the next request loads it in a fresh one.
    private var wanted = false
    /// The helper the model was loaded in, by its number.
    private var loadedIn: Int?
    /// When the model was last used, and the check that ends a helper kept only for it.
    private var lastUsed = Date.distantPast
    private var idleCheck: Task<Void, Never>?
    /// Seconds without a search after which a helper that holds only the search model is ended. The next
    /// search starts a fresh one, which costs about a third of a second. TESTING:
    /// CHIRP_EMBED_IDLE=<seconds> shortens it.
    static let idleSeconds: Double = ProcessInfo.processInfo.environment["CHIRP_EMBED_IDLE"].flatMap(Double.init) ?? 240

    public init() {}

    /// Whether the model is in use and ready to embed.
    public var isLoaded: Bool { wanted }

    /// The turn the search model's requests take: their own, apart from the language model's runs. Queued
    /// behind those runs instead, a search typed during a run waited for the whole of it (measured: 92 s
    /// behind a slow run, against 0.1 to 0.2 s with a lane of its own).
    private var gate: TurnGate { supervisor.embedGate }

    /// Downloads the model if needed and loads it in the helper. `progress` reports 0…1. Does nothing
    /// when it is already loaded there.
    public func load(progress: (@Sendable (Double) -> Void)? = nil) async throws {
        await gate.enter()
        defer { gate.leave() }
        try await loadInHelper(progress: progress)
        wanted = true
        progress?(1)
    }

    /// Makes sure a helper is running and has the model. Call with the turn held.
    private func loadInHelper(progress: (@Sendable (Double) -> Void)?) async throws {
        do {
            let helper = try await supervisor.ensureRunning()
            if loadedIn == helper { return }
            try await supervisor.embedLoad(modelID: HubReference.joined(Self.modelID, revision: Self.revision), progress: progress)
            loadedIn = helper
        } catch let failure as LanguageModelError {
            throw EmbedderError(failure)
        }
    }

    /// Frees the model's memory.
    public func unload() async {
        await gate.enter()
        defer { gate.leave() }
        guard wanted else { return }
        wanted = false
        if loadedIn != nil, loadedIn == supervisor.running { await supervisor.embedUnload() }
        loadedIn = nil
    }

    /// A unit-length vector for each text, in the same order. Set `asQuery` for what the user typed into
    /// search and leave it off for the notes being searched. Text past about 510 tokens is not read.
    public func embed(_ texts: [String], asQuery: Bool = false) async throws -> [[Float]] {
        guard wanted else { throw EmbedderError.notLoaded }
        await gate.enter()
        defer { gate.leave() }
        try Task.checkCancellation()
        try await loadInHelper(progress: nil)
        used()
        do {
            return try await supervisor.embed(texts.map { asQuery ? Self.queryPrefix + $0 : $0 })
        } catch let failure as LanguageModelError {
            throw EmbedderError(failure)
        }
    }

    /// Notes that the model was just used, and makes sure the idle check is running.
    private func used() {
        lastUsed = Date()
        guard idleCheck == nil else { return }
        idleCheck = Task { [weak self] in
            while let self, await self.stillWaitingToGoIdle() {
                try? await Task.sleep(for: .seconds(min(30, Self.idleSeconds / 4)))
            }
        }
    }

    /// One look by the idle check. Once the model has sat unused long enough, a helper that holds nothing
    /// else is ended (with the language model loaded, the helper stays, and goes when that is unloaded).
    /// Returns false when there is nothing left to watch.
    private func stillWaitingToGoIdle() async -> Bool {
        guard wanted, let helper = loadedIn, helper == supervisor.running else {
            idleCheck = nil
            return false
        }
        guard Date().timeIntervalSince(lastUsed) >= Self.idleSeconds else { return true }
        await gate.enter()
        defer { gate.leave() }
        // A search may have come in while this waited its turn.
        guard Date().timeIntervalSince(lastUsed) >= Self.idleSeconds else { return true }
        if await supervisor.endIfOnlySearch(helper) { loadedIn = nil }
        idleCheck = nil
        return false
    }
}
