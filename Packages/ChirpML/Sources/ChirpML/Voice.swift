import ChirpCore
import CoreML
import FluidAudio
import Foundation

/// One synthesized sentence: audio plus when each word is spoken.
public struct SpokenSentence: Sendable {
    /// Mono samples at `sampleRate`.
    public var samples: [Float]
    /// Samples per second of `samples`, as the voice produced them.
    public var sampleRate: Double
    /// One weight per spoken word (its share of the audio), for read-along highlighting.
    public var wordWeights: [Double]
    /// The sounds the voice made, as it wrote them down. Used to check how something will be said.
    public var phonemes: String
    /// When each spoken word is said, from the lengths the voice gave its sounds. Nil when they do not
    /// line up with the sounds (see `WordTiming.spans`).
    public var wordSpans: [SpokenSpan]?
    /// The text the voice really spoke, after it wrote numbers and symbols out as words.
    public var spokenText: String?
    /// Where the time to make this sentence went.
    public var timing: SynthesisTiming?
    /// Length of the audio in seconds.
    public var duration: Double { Double(samples.count) / sampleRate }

    public init(
        samples: [Float], sampleRate: Double, wordWeights: [Double], phonemes: String = "", wordSpans: [SpokenSpan]? = nil,
        spokenText: String? = nil, timing: SynthesisTiming? = nil
    ) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.wordWeights = wordWeights
        self.phonemes = phonemes
        self.wordSpans = wordSpans
        self.spokenText = spokenText
        self.timing = timing
    }
}

/// Where the time to make one sentence went: the whole call, and each of the voice model's seven stages.
/// What is left over is the work before the model (writing numbers out, finding each word's sounds).
public struct SynthesisTiming: Sendable {
    /// The whole call, in milliseconds.
    public var wallMs: Double
    /// Each stage of the model in order, in milliseconds.
    public var stages: [(name: String, ms: Double)]
    /// All the stages together.
    public var modelMs: Double { stages.reduce(0) { $0 + $1.ms } }
    /// The call less the model: text to sounds, and handing the numbers over.
    public var textMs: Double { max(0, wallMs - modelMs) }

    /// One line for the log: "1104 ms: text 612, albert 20, …".
    public var summary: String {
        String(format: "%.0f ms: text %.0f, ", wallMs, textMs) + stages.map { String(format: "%@ %.0f", $0.name, $0.ms) }.joined(separator: ", ")
    }
}

/// Reads text aloud with Kokoro (82M parameters, Apache-2.0), one sentence at a time.
public actor Voice {
    /// A voice the user can pick.
    public struct Option: Sendable, Identifiable, Hashable {
        /// Kokoro's own name for the voice, passed to `speak`. The first letter is the accent and the
        /// second the gender ("af" is American, female).
        public let id: String
        /// The name shown to the user.
        public let name: String
        /// Accent and gender, shown under the name.
        public let accent: String
    }

    /// The English voices, best-sounding first.
    public static let voices: [Option] = [
        .init(id: "af_heart", name: "Heart", accent: "American, female"),
        .init(id: "af_bella", name: "Bella", accent: "American, female"),
        .init(id: "af_nicole", name: "Nicole", accent: "American, female"),
        .init(id: "af_sarah", name: "Sarah", accent: "American, female"),
        .init(id: "am_michael", name: "Michael", accent: "American, male"),
        .init(id: "am_fenrir", name: "Fenrir", accent: "American, male"),
        .init(id: "am_puck", name: "Puck", accent: "American, male"),
        .init(id: "bf_emma", name: "Emma", accent: "British, female"),
        .init(id: "bf_isabella", name: "Isabella", accent: "British, female"),
        .init(id: "bm_george", name: "George", accent: "British, male"),
        .init(id: "bm_fable", name: "Fable", accent: "British, male"),
    ]

    /// The voice used until another is picked: Puck, picked after listening to them all.
    public static let defaultID = "am_puck"

    /// The helper process the voice model runs in (`--voice-worker`, `VoiceEngine`). The app loads no model.
    private let helper = ModelHelper(arguments: [VoiceWorker.flag], what: "reading voice")
    /// The helper the model was loaded in, by its number; nil when it is in none.
    private var loadedIn: Int?
    /// Whether the voice counts as loaded. It stays true while a helper that died is waiting to be
    /// replaced: the next sentence starts a fresh helper and loads the model in it.
    private var loaded = false
    /// The check that ends a helper kept only for its word list (see `unload`).
    private var keepCheck: Task<Void, Never>?
    /// Seconds a helper is kept after the voice is put away, holding only the word list, before it is
    /// ended and all of its memory returned. TESTING: CHIRP_VOICE_KEEP=<seconds> changes it.
    static let keepSeconds: Double = ProcessInfo.processInfo.environment["CHIRP_VOICE_KEEP"].flatMap(Double.init) ?? 600
    /// How long the last sentence took to synthesize, in seconds (diagnostics).
    public private(set) var lastSynthesisSeconds: Double = 0
    /// The load in progress, if any. A second caller waits for it and does not start another.
    private var loading: Task<Void, Error>?
    /// How long the last load took and where it went, for the log.
    public private(set) var lastLoad = ""

    public init() {}

    /// Whether the voice is in memory and ready to speak.
    public var isLoaded: Bool { loaded }

    /// Whether the voice is on disk: each of the model's seven parts and its list of sounds, where
    /// FluidAudio loads them from. (The folder next to it, `kokoro`, holds only the word list; looking for
    /// that alone said "downloaded" when the model itself was missing.)
    public nonisolated static var isDownloaded: Bool { isDownloaded(in: modelDirectory) }

    /// The same, for a given models folder.
    public nonisolated static func isDownloaded(in models: URL) -> Bool {
        let parts = models.appendingPathComponent("kokoro-82m-coreml/ANE")
        let names = KokoroAneStage.allCases.map(\.bundleName) + ["vocab.json"]
        return names.allSatisfy { FileManager.default.fileExists(atPath: parts.appendingPathComponent($0).path) }
    }

    /// Fetches any voice in the menu that is not on disk yet, so each one works later without a
    /// connection (FluidAudio otherwise fetches a voice the first time it is used). Best effort, in the
    /// background, about 0.5 MB a voice on disk; a voice that cannot be fetched now is tried again next time.
    public nonisolated static func fetchMissingVoices() {
        let parts = modelDirectory.appendingPathComponent("kokoro-82m-coreml/ANE")
        let missing = voices.map(\.id).filter { !FileManager.default.fileExists(atPath: parts.appendingPathComponent($0 + ".bin").path) }
        guard !missing.isEmpty else { return }
        Task.detached(priority: .utility) {
            for id in missing {
                _ = try? await KokoroAneResourceDownloader.ensureVoicePack(id, repoDirectory: parts, variant: .english)
            }
        }
    }

    /// Where FluidAudio keeps the voice models. `CHIRP_TTS_DIR` names another folder, for testing a
    /// missing or half-fetched download without touching the real one.
    public nonisolated static var modelDirectory: URL {
        if let other = ProcessInfo.processInfo.environment["CHIRP_TTS_DIR"], !other.isEmpty { return URL(fileURLWithPath: other) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache/fluidaudio/Models")
    }

    /// The folder to hand FluidAudio: nil for its own usual place.
    nonisolated static var customDirectory: URL? {
        ProcessInfo.processInfo.environment["CHIRP_TTS_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
    }

    /// Downloads the voice if needed and loads it. Does nothing when it is already loaded.
    public func load() async throws {
        if let loading { return try await loading.value }
        if loaded { return }
        let task = Task<Void, Error> {
            // Cleared here, on the actor, before anyone waiting on the task carries on.
            defer { self.loading = nil }
            try await self.loadNow()
        }
        loading = task
        try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    /// The load itself. Only ever one at a time: see `load`.
    private func loadNow() async throws {
        keepCheck?.cancel()
        keepCheck = nil
        try await loadInHelper()
        loaded = true
    }

    /// Makes sure a helper is running and has the model in memory.
    private func loadInHelper() async throws {
        let number = try await helper.ensureRunning()
        // Loading can mean downloading the voice the first time: it gets ten minutes of silence.
        let answer = try await helper.call("load", silence: 600)
        lastLoad = String(decoding: answer.json, as: UTF8.self)
        loadedIn = number
    }

    /// Frees the voice model's memory. The helper stays for a while holding the list of how each word is
    /// said: reading that list in (178,000 words) is what made the first sentence after every load take
    /// about a second, far longer than loading the model itself again. If the voice is not wanted again
    /// within `keepSeconds` the helper is ended, and all of its memory goes back to macOS.
    public func unload() async {
        loaded = false
        guard loadedIn != nil, loadedIn == helper.running else {
            loadedIn = nil
            return
        }
        guard Self.keepSeconds > 0, (try? await helper.call("cleanup", silence: 30)) != nil else {
            await helper.stop()
            loadedIn = nil
            return
        }
        keepCheck?.cancel()
        keepCheck = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.keepSeconds))
            guard !Task.isCancelled else { return }
            await self?.endKeptHelper()
        }
    }

    /// The voice was not wanted again in time: end the helper that was kept for its word list.
    private func endKeptHelper() async {
        guard !loaded, loading == nil else { return }
        Self.log("reading voice helper ended: the voice sat unused")
        await helper.stop()
        loadedIn = nil
        keepCheck = nil
    }

    /// Ends the helper at once without waiting, for when the app quits.
    public nonisolated func stopNow() { helper.stopNow() }

    /// Helpers started since launch, and the running one's process id (diagnostics and tests).
    public nonisolated var helperStarts: Int { helper.helperStarts }
    public nonisolated var helperPID: Int32? { helper.helperPID }

    private nonisolated static func log(_ line: String) { ModelHelper.log?(line) }

    /// Synthesizes one sentence. Speeds up to 2× are applied at playback; beyond that the voice itself
    /// speaks faster (`speed` above 1), which sounds better than stretching the audio further.
    public func speak(_ text: String, voice: String, speed: Float = 1.0) async throws -> SpokenSentence {
        guard loaded else { throw SpeechError.notLoaded }
        // The helper it was loaded in has gone (it died, or was ended): this sentence starts a fresh one.
        if loadedIn == nil || loadedIn != helper.running { try await loadInHelper() }
        let started = Date()
        let (made, blob) = try await helper.call(
            "speak", VoiceRequest(text: text, voice: voice, speed: speed),
            silence: 60, as: VoiceAnswer.self)
        lastSynthesisSeconds = Date().timeIntervalSince(started)
        let timing = SynthesisTiming(wallMs: lastSynthesisSeconds * 1000, stages: zip(VoiceAnswer.stageNames, made.stageMs).map { ($0, $1) })
        return SpokenSentence(
            samples: blob.floats, sampleRate: made.sampleRate,
            wordWeights: Self.wordWeights(phonemes: made.phonemes, durations: made.durations),
            phonemes: made.phonemes, wordSpans: WordTiming.spans(phonemes: made.phonemes, durations: made.durations),
            spokenText: made.spokenText, timing: timing)
    }

    /// Per-word durations from the model's own per-phoneme durations. Words in the phoneme string are
    /// separated by spaces; token 0 is the start marker. Falls back to phoneme counts when they do not line up.
    static func wordWeights(phonemes: String, durations: [Int32]) -> [Double] {
        let scalars = Array(phonemes.unicodeScalars)
        let aligned = durations.count == scalars.count + 2
        var weights: [Double] = []
        var current = 0.0
        var hasWord = false
        for (i, scalar) in scalars.enumerated() {
            let d = aligned ? Double(durations[i + 1]) : 1.0
            if scalar == " " {
                if hasWord { weights.append(current + d) }
                current = 0
                hasWord = false
            } else {
                current += d
                hasWord = true
            }
        }
        if hasWord { weights.append(current) }
        return weights
    }
}
