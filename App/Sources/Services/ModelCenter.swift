import ChirpCore
import ChirpML
import Foundation
import Observation

/// The models Chirp can use. Each is downloaded once and then runs entirely on this Mac.
enum ModelKind: String, CaseIterable, Identifiable {
    case transcription
    case language
    case voice
    case speakers
    case search

    var id: String { rawValue }

    /// The model's name as shown to the user.
    var name: String {
        switch self {
        case .transcription: "Parakeet TDT v2"
        case .language: ModelCenter.languageSize.name
        case .voice: "Kokoro"
        case .speakers: "pyannote community-1"
        case .search: "bge-small-en"
        }
    }

    /// One line on what the model is for.
    var purpose: String {
        switch self {
        case .transcription: "Turns speech into text for dictation, voice notes, meetings and audio files."
        case .language:
            ModelCenter.summaryModel.map { "Cleans up and rephrases your own text. Summaries use \($0.name), \(String(format: "%.1f", $0.downloadGB)) GB more, downloaded the first time you summarize." }
                ?? "Cleans up, rephrases and summarizes your own text."
        case .voice: "Reads text aloud in a natural voice."
        case .speakers: "Works out who spoke when, after a meeting."
        case .search: "Finds notes by meaning, not only by exact words."
        }
    }

    /// The speech model's download in megabytes, from the size its file is checked against.
    static var speechMegabytes: Int { Int((Double(Transcriber.modelBytes) / 1_000_000).rounded()) }

    /// Roughly how much it downloads.
    var approximateSize: String {
        switch self {
        case .transcription: "\(Self.speechMegabytes) MB"
        case .language: String(format: "%.1f GB", ModelCenter.languageSize.downloadGB)
        case .voice: "95 MB"
        case .speakers: "100 MB"
        case .search: "130 MB"
        }
    }

    /// The licence the model is released under.
    var license: String {
        switch self {
        case .transcription, .speakers: "CC-BY-4.0"
        case .language, .voice: "Apache-2.0"
        case .search: "MIT"
        }
    }

    /// Needed for the first-run setup; the rest download the first time their feature is used.
    var essential: Bool { self == .transcription }
}

/// Where a model is: not on this Mac, downloading (0…1), on disk, loading into memory, loaded, or failed
/// with the reason.
enum ModelState: Equatable {
    case notDownloaded
    case downloading(Double)
    case onDisk
    case loading
    case loaded
    case failed(String)

    /// True while downloading or loading.
    var isBusy: Bool {
        switch self {
        case .downloading, .loading: true
        default: false
        }
    }
}

/// Owns every model and decides what is in memory. On Macs with little memory only one
/// heavy model is loaded at a time.
@MainActor
@Observable
final class ModelCenter {
    let transcriber = Transcriber()
    let language = LanguageModel()

    /// The language model's helper process as last asked (debug links only): how many have been started, and
    /// the running one's process id (0 for none).
    private var languageWorker: (starts: Int, pid: Int) = (0, 0)

    /// Each model's state, for the screens that show it.
    private(set) var states: [ModelKind: ModelState] = [:]

    // MARK: First-run preparation

    /// True once the speech model answers quickly. On a new install macOS spends a few minutes
    /// preparing it in the background, and dictation is slow until that finishes.
    private(set) var speechPrepared = false
    private var preparing = false

    /// Downloads the speech model when the user starts it in onboarding, then makes it ready. It carries on
    /// when the step that started it is left.
    func startSpeechDownload() {
        guard !state(.transcription).isBusy else { return }
        Task { [weak self] in
            guard let self, (try? await self.ensure(.transcription)) != nil else { return }
            await self.prepareSpeech()
        }
    }

    /// Loads the speech model and waits until it answers quickly, for at most five minutes.
    func prepareSpeech() async {
        guard !speechPrepared, !preparing else { return }
        preparing = true
        defer { preparing = false }
        guard (try? await ensure(.transcription)) != nil else { return }
        let deadline = Date().addingTimeInterval(300)
        while Date() < deadline {
            let seconds = await transcriber.probeSeconds() ?? 0
            Log.write("models", String(format: "speech model probe: %.2f s", seconds))
            if seconds < 1.0 { break }
            // Check sparingly: each check uses the processor macOS needs for the preparation itself.
            try? await Task.sleep(for: .seconds(25))
        }
        speechPrepared = true
    }

    // MARK: Which language model

    /// How much memory this Mac has.
    nonisolated static let memoryBytes = ProcessInfo.processInfo.physicalMemory
    /// Used when the chosen size would not load, until the app is next opened.
    nonisolated(unsafe) private static var sessionFallback: LanguageModelSize?

    /// The user's choice of language model size, or nil to let Chirp pick for this Mac.
    nonisolated static var languageChoice: LanguageModelSize? {
        get { UserDefaults.standard.string(forKey: "languageModelSize").flatMap(LanguageModelSize.init(rawValue:)) }
        set { UserDefaults.standard.set(newValue?.rawValue, forKey: "languageModelSize") }
    }

    /// The size in use right now: the user's, or a smaller one when it would not load.
    nonisolated static var languageSize: LanguageModelSize {
        sessionFallback ?? LanguageModelSize.resolve(choice: languageChoice?.rawValue, memoryBytes: memoryBytes)
    }

    /// A model summaries are written with in place of the general language model.
    struct SummaryModel: Sendable, Equatable {
        /// The hub id.
        var id: String
        /// The commit of the model's repository that is loaded.
        var revision: String
        /// A LoRA adapter on the hub fused in as it loads, "repo@revision".
        var adapter: String?
        /// Asked with the prompt the adapter was trained on (`ReadController.summaryRequest`), not Chirp's own.
        var tldrPrompt: Bool
        var name: String
        var downloadGB: Double
    }

    /// Qwen3-0.6B (8-bit) with the TLDR LoRA, the 2B's replacement for summaries on Macs that use the 2B: as
    /// many wrong statements, in two-thirds the time and with less memory. The model and the adapter are pinned
    /// to the revisions that were measured.
    static let tldrSummaryModel = SummaryModel(
        id: "mlx-community/Qwen3-0.6B-8bit", revision: "11de96878523501bcaa86104e3c186de07ff9068", adapter: "phh/Qwen3-0.6B-TLDR-Lora@0f39534202828516c2645f1aeb8c5e9e9a0f6801",
        tldrPrompt: true, name: "Qwen3 0.6B", downloadGB: 0.7)

    /// The model summaries are written with, or nil when they use the general language model. It takes the general one's
    /// place in the language helper while a summary is written, and the general one comes back for the next other job (one
    /// model at a time). The TLDR model where the general model is the 2B; larger sizes summarize with their own model
    /// (only the 2B was measured against it).
    nonisolated static var summaryModel: SummaryModel? {
        guard !summaryFallback, languageSize == .small else { return nil }
        return tldrSummaryModel
    }
    /// Set when the summary model would not load (no connection for its download, say): the general model summarizes until
    /// the app is next opened.
    nonisolated(unsafe) private static var summaryFallback = false

    /// Whether the summary model and its adapter have been downloaded.
    static var summaryModelOnDisk: Bool {
        guard let summary = summaryModel else { return false }
        return hubModelExists(summary.id) && (summary.adapter.map { hubModelExists(String($0.split(separator: "@")[0])) } ?? true)
    }

    /// Whether the summary in progress is asked with the TLDR prompt: only while the summary model is the one loaded.
    var summaryUsesTLDRPrompt: Bool { languageForSummary && (Self.summaryModel?.tldrPrompt ?? false) }

    /// Whether the language helper holds the summary model (not the general one), and which the next load is for.
    private var languageForSummary = false
    private var languageWantsSummary = false

    /// `ensure(.language)` for a summary: the summary model when there is one, else the general model.
    func ensureSummaryModel() async throws { try await ensureLanguage(forSummary: true) }

    /// Puts the language helper's model away first when it is the other one of the general and the summary model.
    private func ensureLanguage(forSummary: Bool) async throws {
        let wanted = forSummary && Self.summaryModel != nil
        try await waitWhileBusy(.language)
        if state(.language) == .loaded, languageForSummary != wanted { await unload(.language) }
        languageWantsSummary = wanted
        try await ensureLoaded(.language)
    }

    /// The folder name of the sentence checker in Chirp's Models folder: MiniCheck-RoBERTa-Large converted to
    /// safetensors (`Scripts/minicheck-convert.py`), downloaded by `SummaryCheckerDownload` the first time it's needed.
    nonisolated static let summaryCheckerFolder = "minicheck-roberta-large"

    /// The sentence checker summaries use after the rule check, from `~/Library/Application Support/Chirp/Models/minicheck-roberta-large`.
    /// Nil when it is not there: summaries then use the rule check alone, and the log says so once.
    nonisolated static var summaryCheckerDirectory: URL? {
        let folder = ChirpStore.modelsDirectory.appendingPathComponent(summaryCheckerFolder, isDirectory: true)
        guard FileManager.default.fileExists(atPath: folder.appendingPathComponent("model.safetensors").path),
            FileManager.default.fileExists(atPath: folder.appendingPathComponent("config.json").path)
        else {
            if !checkerMissingLogged {
                checkerMissingLogged = true
                Log.write("summary", "sentence checker not found; summaries use the rule check only")
            }
            return nil
        }
        return folder
    }
    nonisolated(unsafe) private static var checkerMissingLogged = false

    /// How many parts of a summary are written together in one batch of the language model (`BatchedGeneration`).
    nonisolated static let summaryBatch = 4

    /// The line under which the checker's "supported" score replaces a point (MiniCheck's own is 0.5).
    nonisolated static let summaryCheckerThreshold = 0.5

    /// Bumped when the language model choice changes, so screens showing its name refresh.
    private(set) var languageVersion = 0

    /// Switches language model size. The old one leaves memory; the new one loads the next time it is needed.
    func chooseLanguage(_ size: LanguageModelSize?) async {
        await unload(.language)
        Self.sessionFallback = nil
        Self.languageChoice = size
        Log.write("models", "language model: \(size?.name ?? "automatic") → \(Self.languageSize.name), Mac has \(MacMemory.wholeGigabytes(Self.memoryBytes)) GB")
        states[.language] = Self.hubModelExists(Self.languageSize.modelID) ? .onDisk : .notDownloaded
        languageVersion += 1
    }

    /// Loads the language model, stepping down a size if the chosen one will not load on this Mac.
    private func loadLanguage(_ report: @escaping @Sendable (Double) -> Void) async throws {
        var size = Self.languageSize
        languageForSummary = false
        if languageWantsSummary, let summary = Self.summaryModel {
            do {
                try await language.load(
                    modelID: HubReference.joined(summary.id, revision: summary.revision), adapterID: summary.adapter, progress: report)
                languageForSummary = true
                Log.write("models", "language model for summaries: \(summary.id)\(summary.adapter.map { " + " + $0 } ?? "")")
                return
            } catch {
                guard !(error is CancellationError) else { throw error }
                Log.write("models", "\(summary.name) did not load (\(error.localizedDescription)); summaries use \(size.name)")
                Self.summaryFallback = true
            }
        }
        while true {
            do {
                if !Self.hubModelExists(size.modelID) {
                    let free = (try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                        .volumeAvailableCapacityForImportantUsage).map { Double($0) / 1_000_000_000 }
                    if let free, free < size.downloadGB + 1 {
                        throw ModelCenterError.noDiskSpace(size.name, size.downloadGB)
                    }
                }
                try await language.load(modelID: size.hubReference, progress: report)
                return
            } catch {
                guard let smaller = size.smaller, !(error is CancellationError) else { throw error }
                Log.write("models", "\(size.name) did not load (\(error.localizedDescription)); using \(smaller.name)")
                Toast.show("\(size.name) could not be used on this Mac. Using \(smaller.name) for now.", seconds: 6)
                Self.sessionFallback = smaller
                languageVersion += 1
                size = smaller
            }
        }
    }

    /// Under about 12 GB, loading one heavy model unloads the others first (`MacMemory`).
    let lowMemory = MacMemory.keepsOneHeavyModel(memoryBytes: ModelCenter.memoryBytes)

    /// Extra loaders and unloaders registered by features built on other models (voice, meeting…).
    private var loaders: [ModelKind: @MainActor (@escaping @Sendable (Double) -> Void) async throws -> Void] = [:]
    private var unloaders: [ModelKind: @MainActor () async -> Void] = [:]
    private var diskChecks: [ModelKind: () -> Bool] = [:]

    /// How long each model took to load, in seconds (for diagnostics).
    private(set) var loadSeconds: [ModelKind: Double] = [:]
    /// When each model was last asked for, to unload the ones sitting idle.
    private var lastUsed: [ModelKind: Date] = [:]
    /// How many jobs are using each model right now. A model in use is not unloaded for sitting idle or
    /// to make room for another: a job that calls it many times (notes for a long meeting) would fail halfway.
    private var inUse: [ModelKind: Int] = [:]

    /// Says a job that will call `kind` several times has begun. Pair with `endUse`.
    func beginUse(_ kind: ModelKind) {
        inUse[kind, default: 0] += 1
        lastUsed[kind] = Date()
    }

    /// Says that job is over. The model can be unloaded again once it has sat idle.
    func endUse(_ kind: ModelKind) {
        inUse[kind] = max(0, (inUse[kind] ?? 0) - 1)
        lastUsed[kind] = Date()
    }

    /// Whether any job is using `kind` right now.
    func isInUse(_ kind: ModelKind) -> Bool { (inUse[kind] ?? 0) > 0 }
    /// How many jobs are using the model now.
    func useCount(_ kind: ModelKind) -> Int { inUse[kind] ?? 0 }

    init() {
        LinkHandler.stateProviders["models"] = { [weak self] in
            guard let self else { return [:] }
            var out: [String: String] = [:]
            for kind in ModelKind.allCases {
                out[kind.rawValue] = "\(self.state(kind))" + (self.loadSeconds[kind].map { String(format: " (%.1fs)", $0) } ?? "")
            }
            return out
        }
        // On small Macs, let go of models that hold real memory once they have sat unused for a few minutes.
        if lowMemory {
            Task { [weak self] in
                while true {
                    try? await Task.sleep(for: .seconds(60))
                    guard let self else { return }
                    for kind in Self.heavy where self.state(kind) == .loaded && !self.isInUse(kind) {
                        // The voice stays longer: reading a selection every so often should not wait for it each time.
                        let limit: Double = kind == .voice ? 1800 : 240
                        if Date().timeIntervalSince(self.lastUsed[kind] ?? .distantPast) > limit { await self.unload(kind) }
                    }
                }
            }
        }
        Task { [language] in await language.onNote { Log.write("models", $0) } }
        // Every helper's starts, stops, deaths and time-outs go to the log.
        ModelHelper.log = { Log.write("models", $0) }
        LinkHandler.stateProviders["helpers"] = {
            Dictionary(ModelHelper.all.map { ($0.name, ["pid": Int($0.helperPID ?? 0), "starts": $0.helperStarts]) }, uniquingKeysWith: { $1 })
        }
        // TESTING: `chirp://debug/helper-fault?what=reading%20voice&do=kill:speak` has that helper end itself
        // as its next "speak" requests start (`kill-after:speak:200` that many milliseconds in, `hang:speak`
        // never answers; `*` for every request; `do=` alone clears it). `what` is "reading voice",
        // "voice detection" or "speaker labelling".
        LinkHandler.commands["helper-fault"] = { q in
            let fault = q["do"] ?? ""
            for helper in ModelHelper.all where helper.name == q["what"] { Task { await helper.setTestFault(fault) } }
        }
        LinkHandler.stateProviders["languageWorker"] = { [weak self] in
            guard let self else { return [:] }
            return ["starts": self.languageWorker.starts, "pid": self.languageWorker.pid]
        }
        // TESTING: `chirp://debug/llm-fault?do=kill:5` makes the helper end itself after five pieces of the
        // next answers (`hang:5` stops it answering, `fail` refuses the run); `do=` alone clears it.
        // `chirp://debug/llm-worker` refreshes what `state` says about the helper.
        LinkHandler.commands["llm-fault"] = { [language] q in
            let fault = q["do"].flatMap { $0.isEmpty ? nil : $0 }
            Task { await language.setFault(fault) }
        }
        LinkHandler.commands["llm-worker"] = { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.languageWorker = (await self.language.workerStarts, Int(await self.language.workerPID ?? 0))
            }
        }
        diskChecks[.transcription] = { Transcriber.isDownloaded }
        diskChecks[.language] = { Self.hubModelExists(Self.languageSize.modelID) }
        Log.write("models", "Mac has \(MacMemory.wholeGigabytes(Self.memoryBytes)) GB; language model \(Self.languageSize.name) (\(Self.languageChoice == nil ? "automatic" : "chosen"))")
        refresh()
    }

    /// The state of one model; not downloaded until known otherwise.
    func state(_ kind: ModelKind) -> ModelState { states[kind] ?? .notDownloaded }

    /// Adds a model that another feature owns: how to tell it is on disk, and how to load and unload it.
    func register(
        _ kind: ModelKind, onDisk: @escaping () -> Bool,
        load: @escaping @MainActor (@escaping @Sendable (Double) -> Void) async throws -> Void,
        unload: @escaping @MainActor () async -> Void
    ) {
        diskChecks[kind] = onDisk
        loaders[kind] = load
        unloaders[kind] = unload
        if !state(kind).isBusy, state(kind) != .loaded {
            states[kind] = onDisk() ? .onDisk : .notDownloaded
        }
    }

    /// Checks again which models are on disk. Leaves alone any that are loaded or busy.
    func refresh() {
        for kind in ModelKind.allCases where !state(kind).isBusy && state(kind) != .loaded {
            states[kind] = (diskChecks[kind]?() ?? false) ? .onDisk : .notDownloaded
        }
    }

    /// Makes sure `kind` is downloaded and in memory, freeing other heavy models first when memory is short
    /// (but never one that is in use). When it is already loaded this only notes that it was asked for.
    func ensure(_ kind: ModelKind) async throws {
        if kind == .language { try await ensureLanguage(forSummary: false) } else { try await ensureLoaded(kind) }
    }

    private func ensureLoaded(_ kind: ModelKind) async throws {
        lastUsed[kind] = Date()
        if state(kind) == .loaded { return }
        // Another caller is already loading it: wait for that to finish.
        try await waitWhileBusy(kind)
        if state(kind) == .loaded { return }

        if lowMemory {
            for other in ModelKind.allCases
            where other != kind && state(other) == .loaded && Self.heavy.contains(other) && !isInUse(other) {
                // Putting a model away waits for the request it is in the middle of. That wait has a limit:
                // the caller is told the other model is busy, and two heavy models are never loaded together.
                guard await Deadline.run(seconds: Self.unloadWait, { await self.unload(other) }) != nil else {
                    Log.write("models", "\(other.name) was not put away within \(Int(Self.unloadWait)) s to make room for \(kind.name)")
                    throw ModelCenterError.busy(other.name)
                }
            }
            // Unloading waited: another caller may have loaded this model, or begun to, meanwhile.
            try await waitWhileBusy(kind)
            if state(kind) == .loaded { return }
        }
        // The summary model is on disk or not on its own: when it is not, its download shows as the language model's.
        let wasOnDisk = kind == .language && languageWantsSummary && Self.summaryModel != nil
            ? Self.summaryModelOnDisk : diskChecks[kind]?() ?? false
        states[kind] = wasOnDisk ? .loading : .downloading(0)
        let report: @Sendable (Double) -> Void = { [weak self] fraction in
            Task { @MainActor in
                guard let self, case .downloading = self.state(kind) else { return }
                self.states[kind] = fraction >= 1 ? .loading : .downloading(fraction)
            }
        }
        let started = Date()
        do {
            let load: @MainActor @Sendable () async throws -> Void = { [self] in
                switch kind {
                case .transcription: try await transcriber.load(progress: report)
                case .language: try await loadLanguage(report)
                default:
                    guard let load = loaders[kind] else { throw ModelCenterError.unavailable(kind.name) }
                    try await load(report)
                }
            }
            // A model already on this Mac loads in seconds. One that has not come back after five minutes is
            // given up on, so the next request starts again instead of waiting behind it for ever. A
            // download has no such limit: it takes as long as the connection needs, and shows its progress.
            if wasOnDisk { try await Deadline.attempt(seconds: Self.loadLimit) { try await load() } } else { try await load() }
            states[kind] = .loaded
            loadSeconds[kind] = Date().timeIntervalSince(started)
        } catch {
            let passed = error is Deadline.Passed
            if passed { Log.write("models", "\(kind.name) did not load in \(Int(Self.loadLimit)) s") }
            let failure: Error = passed ? ModelCenterError.tookTooLong(kind.name) : error
            states[kind] = .failed(failure.localizedDescription)
            throw failure
        }
    }

    /// Seconds a model that is on disk gets to load.
    static let loadLimit: Double = 300
    /// Seconds a caller waits for a load that someone else began (a download: an hour).
    static let busyWait: Double = 330
    /// Seconds a model gets to be put away to make room for another.
    static let unloadWait: Double = 30

    /// Waits while `kind` is being loaded or downloaded for another caller, for so long and no longer.
    /// (This loop had no limit: a load that never came back held every later caller, a recording's
    /// finishing step among them.)
    private func waitWhileBusy(_ kind: ModelKind) async throws {
        let began = Date()
        while state(kind).isBusy {
            var limit = Self.busyWait
            if case .downloading = state(kind) { limit = 3600 }
            if Date().timeIntervalSince(began) > limit {
                Log.write("models", "\(kind.name) was still \(state(kind) == .loading ? "loading" : "downloading") after \(Int(limit)) s; no longer waiting for it")
                throw ModelCenterError.tookTooLong(kind.name)
            }
            try await Task.sleep(for: .milliseconds(150))
        }
    }

    /// The speech model is unloaded after a quiet spell (five minutes by default)
    /// and loaded again when the next recording starts. A recording in progress keeps it.
    /// Minutes of quiet before the speech model is unloaded: -1 never, 0 right after each use.
    static var speechUnloadMinutes: Int {
        get { UserDefaults.standard.object(forKey: "speechUnloadMinutes") as? Int ?? 5 }
        set { UserDefaults.standard.set(newValue, forKey: "speechUnloadMinutes") }
    }
    /// "auto" (the graphics chip, with the processor as fallback) or "cpu".
    static var speechBackend: String {
        get { UserDefaults.standard.string(forKey: "speechBackend") ?? "auto" }
        set { UserDefaults.standard.set(newValue, forKey: "speechBackend") }
    }
    private var idleWatcher: Task<Void, Never>?

    /// Starts the check that unloads the speech model after a quiet spell.
    func watchSpeechIdle() {
        guard idleWatcher == nil else { return }
        idleWatcher = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard let self, self.state(.transcription) == .loaded else { continue }
                let idle = await Date().timeIntervalSince(self.transcriber.lastUsed)
                let minutes = Self.speechUnloadMinutes
                if minutes > 0, await self.transcriber.holds == 0, idle > Double(minutes) * 60 {
                    await self.unload(.transcription)
                    Log.write("models", "speech model unloaded after \(Int(idle)) s idle")
                }
            }
        }
    }

    /// Takes a loaded model out of memory. Its files stay on disk.
    func unload(_ kind: ModelKind) async {
        guard state(kind) == .loaded else { return }
        switch kind {
        case .transcription: await transcriber.unload()
        case .language: await language.unload()
        default: await unloaders[kind]?()
        }
        states[kind] = .onDisk
    }

    /// Models that give way to each other when memory is short. The speech model is not one of them:
    /// it lives in the worker process and is unloaded on its own timer (`speechUnloadMinutes`).
    static let heavy: Set<ModelKind> = [.language, .voice]

    /// Whether a model from the Hugging Face hub has been downloaded.
    static func hubModelExists(_ id: String) -> Bool {
        FileManager.default.fileExists(atPath: hubModelDirectory(id).path)
    }

    /// Where the hub keeps a downloaded model.
    static func hubModelDirectory(_ id: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub/models--" + id.replacingOccurrences(of: "/", with: "--"))
    }
}

/// Why a model could not be made ready, in words for the user.
enum ModelCenterError: LocalizedError {
    case unavailable(String)
    case noDiskSpace(String, Double)
    /// A model did not load, or was not ready, within its limit.
    case tookTooLong(String)
    /// Another model is in the middle of something and could not be put away to make room.
    case busy(String)

    var errorDescription: String? {
        switch self {
        case .noDiskSpace(let name, let gb): "There is not enough free disk space to download \(name) (\(String(format: "%.1f", gb)) GB)."
        case .unavailable(let name): "\(name) is not available yet."
        case .tookTooLong(let name): "\(name) took too long to load. Try again."
        case .busy(let name): "\(name) is busy. Try again in a moment."
        }
    }
}
